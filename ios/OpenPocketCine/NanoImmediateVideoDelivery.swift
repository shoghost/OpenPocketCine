#if OPENPOCKETCINE_DIAGNOSTICS
import AVFoundation
import CoreMedia
import Foundation
import OpenPocketViewCore

/// Test-only immediate Nano presentation path.
///
/// Complete AUs have already passed through `NanoArrivalJitterBuffer`. This class performs the
/// same AVC NAL parsing, AVCC conversion, sample timing and DisplayImmediately attachment as the
/// Production identity path, but owns all per-frame work on one serial queue. The display layer is
/// still created and attached on MainActor; only its iOS 17 sample-buffer renderer is retained here.
final class NanoImmediateVideoDelivery: @unchecked Sendable {
    static let displayImmediately = true
    static let usesProductionPresentTiming = true
    static let mainActorHopsBeforeRendererEnqueue = 0

    enum BackpressureAction: Equatable, Sendable {
        case enqueue
        case wait
    }

    enum Event: Sendable {
        case format(width: Int32, height: Int32, nalTypes: Set<Int>, changed: Bool)
        case enqueued(isIDR: Bool, nalTypes: Set<Int>)
        case reset(reason: String)
    }

    private struct PendingSample: @unchecked Sendable {
        let sample: CMSampleBuffer
        let accessUnit: LivePacedAccessUnit
        let sourceOrder: Int64
        let nalTypes: Set<Int>
        let isIDR: Bool
    }

    private let renderer: AVSampleBufferVideoRenderer
    private let deliveryQueue = DispatchQueue(
        label: "opv.nano.immediate-delivery", qos: .userInteractive)
    private let eventHandler: @Sendable (Event) -> Void

    // deliveryQueue-owned state.
    private var pending: [PendingSample] = []
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var builtSPS: [UInt8]?
    private var builtPPS: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var frameIndex: Int64 = 0
    private var sourceAnchorRaw: UInt32?
    private var sourceAnchorUnwrapped: Int64?
    private var awaitingIDR = false
    private var stopped = false
    private var readyRequestStarted = false
    private var scheduledDrain = false
    private var nextAllowedEnqueueAt: TimeInterval?

    init(
        renderer: AVSampleBufferVideoRenderer,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) {
        self.renderer = renderer
        self.eventHandler = eventHandler
        deliveryQueue.async { [weak self] in self?.startReadyRequest() }
        ControlLiveLog.line(
            "nano-immediate-delivery: renderer_api=sampleBufferRenderer queue=opv.nano.immediate-delivery display_immediately=true production_pts=true main_actor_hop_count_per_frame=0")
    }

    /// Thread-safe entry called directly by the 200 ms source-clock buffer output.
    func push(_ accessUnit: LivePacedAccessUnit) {
        let now = ProcessInfo.processInfo.systemUptime
        LiveFramePacingDiagnostics.shared.noteDeliveryQueueInput(accessUnit.trace, at: now)
        deliveryQueue.async { [weak self] in self?.accept(accessUnit) }
    }

    func reset(reason: String) {
        deliveryQueue.async { [weak self] in
            self?.resetState(reason: reason, flushRenderer: true)
        }
    }

    func stop() {
        deliveryQueue.async { [weak self] in
            guard let self, !stopped else { return }
            stopped = true
            pending.removeAll(keepingCapacity: false)
            renderer.stopRequestingMediaData()
            renderer.flush()
            eventHandler(.reset(reason: "stop"))
        }
    }

    static func backpressureAction(isReadyForMoreMediaData: Bool) -> BackpressureAction {
        isReadyForMoreMediaData ? .enqueue : .wait
    }

    static func orderedIDs(_ ids: [UInt64]) -> [UInt64] { ids }

    static func sampleTiming(frameIndex: Int64) -> CMSampleTimingInfo {
        LiveViewPresentTiming.sampleTiming(frameIndex: frameIndex)
    }

    private func startReadyRequest() {
        dispatchPrecondition(condition: .onQueue(deliveryQueue))
        guard !stopped, !readyRequestStarted else { return }
        readyRequestStarted = true
        renderer.requestMediaDataWhenReady(on: deliveryQueue) { [weak self] in
            self?.drainOneIfReady()
        }
    }

    private func accept(_ accessUnit: LivePacedAccessUnit) {
        dispatchPrecondition(condition: .onQueue(deliveryQueue))
        guard !stopped else { return }

        let nals = Hevc.nalUnits(accessUnit.bytes).filter { !$0.isEmpty }
        var slices: [[UInt8]] = []
        var nalTypes = Set<Int>()
        for nal in nals {
            let type = Avc.nalType(nal[0])
            nalTypes.insert(type)
            switch type {
            case Avc.sps: sps = nal
            case Avc.pps: pps = nal
            case let value where Avc.isVCL(value): slices.append(nal)
            default: break
            }
        }

        let formatChanged = updateFormatIfReady(nalTypes: nalTypes)
        if formatChanged {
            // Production's identity path flushes only for a real format change/failure. Never flush
            // merely because the renderer temporarily reports backpressure.
            renderer.flush()
            pending.removeAll(keepingCapacity: true)
            awaitingIDR = true
            nextAllowedEnqueueAt = nil
        }
        guard let format, !slices.isEmpty else { return }

        let isIDR = slices.contains { Avc.nalType($0[0]) == Avc.idr }
        if awaitingIDR {
            guard isIDR else { return }
            awaitingIDR = false
        }

        frameIndex += 1
        let buildAt = ProcessInfo.processInfo.systemUptime
        guard let sample = makeSampleBuffer(
            slices: slices, format: format,
            timing: Self.sampleTiming(frameIndex: frameIndex))
        else { return }
        LiveFramePacingDiagnostics.shared.noteSampleBuild(accessUnit.trace, at: buildAt)

        pending.append(
            PendingSample(
                sample: sample, accessUnit: accessUnit,
                sourceOrder: unwrap(accessUnit.trace.sourceTimestamp),
                nalTypes: nalTypes, isIDR: isIDR))
        drainOneIfReady()
    }

    private func drainOneIfReady() {
        dispatchPrecondition(condition: .onQueue(deliveryQueue))
        guard !stopped, !scheduledDrain, !pending.isEmpty else { return }
        if renderer.status == .failed {
            resetState(reason: "renderer_failed", flushRenderer: true)
            return
        }
        if renderer.requiresFlushToResumeDecoding {
            resetState(reason: "renderer_requires_flush", flushRenderer: true)
            return
        }
        guard renderer.isReadyForMoreMediaData else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if let nextAllowedEnqueueAt, now < nextAllowedEnqueueAt {
            scheduledDrain = true
            deliveryQueue.asyncAfter(deadline: .now() + (nextAllowedEnqueueAt - now)) {
                [weak self] in
                guard let self else { return }
                scheduledDrain = false
                drainOneIfReady()
            }
            return
        }

        let entry = pending.removeFirst()
        renderer.enqueue(entry.sample)
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        LiveFramePacingDiagnostics.shared.noteRendererEnqueue(entry.accessUnit.trace, at: enqueuedAt)
        LiveFramePacingDiagnostics.shared.noteDisplaySubmit(entry.accessUnit.trace)
        eventHandler(.enqueued(isIDR: entry.isIDR, nalTypes: entry.nalTypes))

        // Normal operation has no pending backlog because the source-clock buffer emits one AU at
        // a time. If renderer backpressure accumulated AUs, preserve their source spacing instead
        // of burst catch-up when readiness returns.
        if let next = pending.first {
            let deltaMs = max(0, next.sourceOrder - entry.sourceOrder)
            nextAllowedEnqueueAt = enqueuedAt + TimeInterval(deltaMs) / 1_000
            scheduledDrain = true
            deliveryQueue.asyncAfter(deadline: .now() + TimeInterval(deltaMs) / 1_000) {
                [weak self] in
                guard let self else { return }
                scheduledDrain = false
                drainOneIfReady()
            }
        } else {
            nextAllowedEnqueueAt = nil
        }
    }

    /// Returns true only for a change after an active format already existed.
    private func updateFormatIfReady(nalTypes: Set<Int>) -> Bool {
        guard let sps, let pps else { return false }
        if format != nil, sps == builtSPS, pps == builtPPS { return false }
        let hadFormat = format != nil
        var nextFormat: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &nextFormat)
            }
        }
        guard status == noErr, let nextFormat else { return false }
        format = nextFormat
        builtSPS = sps
        builtPPS = pps
        let dimensions = CMVideoFormatDescriptionGetDimensions(nextFormat)
        eventHandler(
            .format(
                width: dimensions.width, height: dimensions.height, nalTypes: nalTypes,
                changed: hadFormat))
        return hadFormat
    }

    private func makeSampleBuffer(
        slices: [[UInt8]], format: CMVideoFormatDescription, timing: CMSampleTimingInfo
    ) -> CMSampleBuffer? {
        var avcc: [UInt8] = []
        avcc.reserveCapacity(slices.reduce(0) { $0 + 4 + $1.count })
        for nal in slices {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }

        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
                == kCMBlockBufferNoErr,
            let block
        else { return nil }
        let copyStatus = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var mutableTiming = timing
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &mutableTiming,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample
        else { return nil }

        if Self.displayImmediately,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func resetState(reason: String, flushRenderer: Bool) {
        dispatchPrecondition(condition: .onQueue(deliveryQueue))
        pending.removeAll(keepingCapacity: true)
        sps = nil
        pps = nil
        builtSPS = nil
        builtPPS = nil
        format = nil
        frameIndex = 0
        sourceAnchorRaw = nil
        sourceAnchorUnwrapped = nil
        awaitingIDR = true
        scheduledDrain = false
        nextAllowedEnqueueAt = nil
        if flushRenderer { renderer.flush() }
        eventHandler(.reset(reason: reason))
    }

    private func unwrap(_ timestamp: UInt32?) -> Int64 {
        guard let timestamp else { return pending.last.map { $0.sourceOrder + 33 } ?? 0 }
        guard let anchorRaw = sourceAnchorRaw, let anchor = sourceAnchorUnwrapped else {
            sourceAnchorRaw = timestamp
            sourceAnchorUnwrapped = Int64(timestamp)
            return Int64(timestamp)
        }
        let delta = Int64(Int32(bitPattern: timestamp &- anchorRaw))
        let value = anchor + delta
        if delta > 0 {
            sourceAnchorRaw = timestamp
            sourceAnchorUnwrapped = value
        }
        return value
    }
}
#endif
