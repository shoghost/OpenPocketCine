#if OPENPOCKETCINE_DIAGNOSTICS
import AVFoundation
import CoreMedia
import Foundation

/// Test-target-only timed presentation for complete Nano AVC access units.
///
/// Complete AUs arrive on the datalink queue and are immediately copied onto `feederQueue`. The
/// queue owns parameter-set parsing, AVCC conversion, timing and renderer backpressure. UIKit layer
/// attachment remains on MainActor, but no per-frame presentation work waits for MainActor.
final class NanoTimedVideoRenderer: @unchecked Sendable {
    static let framesPerSecond: Int32 = 30
    static let prerollAccessUnits = 12
    static let maximumPendingAccessUnits = 60
    static let initialLeadSeconds = 0.400
    static let minimumLeadSeconds = 0.250
    static let maximumLeadSeconds = 0.550
    static let displayImmediately = false

    enum Event: Sendable {
        case format(width: Int32, height: Int32, nalTypes: Set<Int>)
        case enqueued(isIDR: Bool, nalTypes: Set<Int>)
        case controlledReset(reason: String)
    }

    enum ResetReason: Equatable, Sendable {
        case formatChange
        case rendererFailure
        case requiresFlush
        case overflow
        case reconnect
    }

    enum BackpressureAction: Equatable, Sendable {
        case wait
        case enqueue
    }

    struct Timeline: Equatable, Sendable {
        static let timescale: Int32 = 30_000
        private(set) var anchor: CMTime
        private(set) var frameIndex: Int64 = 0

        init(anchor: CMTime) { self.anchor = anchor }

        mutating func nextTiming() -> CMSampleTimingInfo {
            let duration = CMTime(value: 1_000, timescale: Self.timescale)
            let pts = CMTimeAdd(
                anchor,
                CMTime(value: frameIndex * 1_000, timescale: Self.timescale))
            frameIndex += 1
            return CMSampleTimingInfo(
                duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        }

        mutating func reanchor(_ nextAnchor: CMTime) {
            anchor = nextAnchor
            frameIndex = 0
        }
    }

    private struct PendingAU: Sendable {
        let accessUnit: LivePacedAccessUnit
        let sourceOrder: Int64
        let arrivalOrder: UInt64
        let nals: [[UInt8]]
        let slices: [[UInt8]]
        let nalTypes: Set<Int>
        let isIDR: Bool
    }

    private let renderer: AVSampleBufferVideoRenderer
    private let feederQueue = DispatchQueue(label: "opv.nano.timed-renderer", qos: .userInteractive)
    private let eventHandler: @Sendable (Event) -> Void

    // feederQueue-owned state.
    private var pending: [PendingAU] = []
    private var sourceAnchorRaw: UInt32?
    private var sourceAnchorUnwrapped: Int64?
    private var arrivalOrder: UInt64 = 0
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var builtSPS: [UInt8]?
    private var builtPPS: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var timeline: Timeline?
    private var started = false
    private var awaitingIDR = true
    private var stopped = false
    private var readyRequestStarted = false
    private var enqueueCount = 0
    private var readyFalseCount = 0
    private var flushCount = 0
    private var startCount = 0
    private var rebufferCount = 0
    private var resyncCount = 0
    private var lastEnqueueAt: TimeInterval?
    private var lastSummaryAt: TimeInterval = 0
    private var enqueueIntervals: [TimeInterval] = []
    private var scheduledLeads: [Double] = []
    private var ptsIntervals: [Double] = []
    private var lastPTS: CMTime?
    private var refillScheduled = false

    init(
        renderer: AVSampleBufferVideoRenderer,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) {
        self.renderer = renderer
        self.eventHandler = eventHandler
        feederQueue.async { [weak self] in self?.startReadyRequest() }
        ControlLiveLog.line(
            "timed-renderer: display_immediately=false nominal_fps=30 initial_lead_ms=400 renderer_api=sampleBufferRenderer")
    }

    /// Thread-safe entry called directly after the datalink completes an AVC AU.
    func push(_ accessUnit: LivePacedAccessUnit) {
        feederQueue.async { [weak self] in
            self?.accept(accessUnit)
        }
    }

    func reset(reason: String) {
        feederQueue.async { [weak self] in
            self?.controlledReset(reason: .reconnect, detail: reason, removePending: true)
        }
    }

    func stop() {
        feederQueue.async { [weak self] in
            guard let self else { return }
            stopped = true
            pending.removeAll(keepingCapacity: false)
            renderer.stopRequestingMediaData()
            renderer.flush()
            flushCount += 1
            readyRequestStarted = false
            logSummary(reason: "stop")
        }
    }

    static func shouldStart(pendingVideoAccessUnits: Int) -> Bool {
        pendingVideoAccessUnits >= prerollAccessUnits
    }

    static func backpressureAction(isReadyForMoreMediaData: Bool) -> BackpressureAction {
        isReadyForMoreMediaData ? .enqueue : .wait
    }

    static func shouldFlush(for reason: ResetReason) -> Bool {
        switch reason {
        case .formatChange, .rendererFailure, .requiresFlush, .reconnect:
            return true
        case .overflow:
            return false
        }
    }

    static func orderedArrivalIDs(for keys: [(sourceOrder: Int64, arrivalOrder: UInt64)]) -> [UInt64] {
        keys.sorted {
            $0.sourceOrder == $1.sourceOrder
                ? $0.arrivalOrder < $1.arrivalOrder : $0.sourceOrder < $1.sourceOrder
        }.map(\.arrivalOrder)
    }

    private func startReadyRequest() {
        dispatchPrecondition(condition: .onQueue(feederQueue))
        guard !stopped, !readyRequestStarted else { return }
        readyRequestStarted = true
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        CMTimebaseSetTime(renderer.timebase, time: hostNow)
        CMTimebaseSetRate(renderer.timebase, rate: 1)
        renderer.requestMediaDataWhenReady(on: feederQueue) { [weak self] in
            self?.drain()
        }
    }

    private func accept(_ accessUnit: LivePacedAccessUnit) {
        dispatchPrecondition(condition: .onQueue(feederQueue))
        guard !stopped else { return }
        let nals = Hevc.nalUnits(accessUnit.bytes).filter { !$0.isEmpty }
        var slices: [[UInt8]] = []
        var types = Set<Int>()
        var incomingSPS: [UInt8]?
        var incomingPPS: [UInt8]?
        for nal in nals {
            let type = Avc.nalType(nal[0])
            types.insert(type)
            switch type {
            case Avc.sps: incomingSPS = nal
            case Avc.pps: incomingPPS = nal
            case let value where Avc.isVCL(value): slices.append(nal)
            default: break
            }
        }
        if let incomingSPS { sps = incomingSPS }
        if let incomingPPS { pps = incomingPPS }
        let formatChanged = updateFormatIfReady()
        if formatChanged {
            controlledReset(reason: .formatChange, detail: "format_change", removePending: true)
        }
        guard !slices.isEmpty, format != nil else {
            logSummaryIfNeeded()
            return
        }
        let idr = slices.contains { Avc.nalType($0[0]) == Avc.idr }
        if awaitingIDR {
            guard idr else {
                logSummaryIfNeeded()
                return
            }
            awaitingIDR = false
        }

        if pending.count >= Self.maximumPendingAccessUnits {
            // Compressed dependencies prohibit dropping one old P-frame. Discard the whole pending
            // chain and resume only at a clean IDR.
            controlledReset(reason: .overflow, detail: "pending_overflow", removePending: true)
            guard idr else { return }
            awaitingIDR = false
        }

        arrivalOrder &+= 1
        let sourceOrder = unwrapSourceTimestamp(accessUnit.trace.sourceTimestamp)
        pending.append(
            PendingAU(
                accessUnit: accessUnit, sourceOrder: sourceOrder, arrivalOrder: arrivalOrder,
                nals: nals, slices: slices, nalTypes: types, isIDR: idr))
        pending.sort {
            $0.sourceOrder == $1.sourceOrder
                ? $0.arrivalOrder < $1.arrivalOrder : $0.sourceOrder < $1.sourceOrder
        }
        if !started, Self.shouldStart(pendingVideoAccessUnits: pending.count) {
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let anchor = CMTimeAdd(
                hostNow, CMTime(seconds: Self.initialLeadSeconds, preferredTimescale: 1_000_000))
            timeline = Timeline(anchor: anchor)
            started = true
            startCount += 1
        }
        drain()
        logSummaryIfNeeded()
    }

    private func drain() {
        dispatchPrecondition(condition: .onQueue(feederQueue))
        guard !stopped, started, var localTimeline = timeline else { return }
        if renderer.status == .failed {
            controlledReset(reason: .rendererFailure, detail: "renderer_failed", removePending: true)
            return
        }
        if renderer.requiresFlushToResumeDecoding {
            controlledReset(reason: .requiresFlush, detail: "requires_flush", removePending: true)
            return
        }
        guard renderer.isReadyForMoreMediaData else {
            readyFalseCount += 1
            logSummaryIfNeeded()
            return
        }

        while renderer.isReadyForMoreMediaData, !pending.isEmpty {
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let timelineBeforeCandidate = localTimeline
            let nextPTS = localTimeline.nextTiming().presentationTimeStamp
            let lead = CMTimeGetSeconds(CMTimeSubtract(nextPTS, hostNow))
            if lead > Self.maximumLeadSeconds {
                localTimeline = timelineBeforeCandidate
                scheduleRefill(after: min(Self.maximumLeadSeconds / 4, lead - Self.maximumLeadSeconds))
                break
            }
            if lead <= 0 {
                // Renderer consumed its future reserve. Keep the dependency chain, collect a fresh
                // 12-AU reserve, and use a new host-time anchor without burst catch-up.
                started = false
                timeline = nil
                rebufferCount += 1
                if pending.count >= Self.prerollAccessUnits {
                    let anchor = CMTimeAdd(
                        hostNow,
                        CMTime(seconds: Self.initialLeadSeconds, preferredTimescale: 1_000_000))
                    localTimeline.reanchor(anchor)
                    started = true
                    startCount += 1
                    continue
                }
                break
            }
            let entry = pending.removeFirst()
            guard let format, let sample = makeSampleBuffer(
                slices: entry.slices, format: format,
                timing: CMSampleTimingInfo(
                    duration: CMTime(value: 1_000, timescale: Timeline.timescale),
                    presentationTimeStamp: nextPTS, decodeTimeStamp: .invalid))
            else {
                controlledReset(reason: .rendererFailure, detail: "sample_build_failed", removePending: true)
                return
            }
            renderer.enqueue(sample)
            timeline = localTimeline
            noteEnqueue(pts: nextPTS, lead: lead)
            LiveFramePacingDiagnostics.shared.noteDisplaySubmit(entry.accessUnit.trace)
            eventHandler(.enqueued(isIDR: entry.isIDR, nalTypes: entry.nalTypes))
        }
        timeline = localTimeline
        if !renderer.isReadyForMoreMediaData { readyFalseCount += 1 }
        logSummaryIfNeeded()
    }

    /// Returns true only when an already-active format changed.
    private func updateFormatIfReady() -> Bool {
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
        eventHandler(.format(width: dimensions.width, height: dimensions.height, nalTypes: [7, 8]))
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
        // Deliberately do not set kCMSampleAttachmentKey_DisplayImmediately. Future PTS must govern.
        return sample
    }

    private func controlledReset(reason: ResetReason, detail: String, removePending: Bool) {
        dispatchPrecondition(condition: .onQueue(feederQueue))
        if Self.shouldFlush(for: reason) {
            renderer.flush()
            flushCount += 1
        }
        if removePending { pending.removeAll(keepingCapacity: true) }
        started = false
        timeline = nil
        awaitingIDR = true
        sourceAnchorRaw = nil
        sourceAnchorUnwrapped = nil
        resyncCount += 1
        eventHandler(.controlledReset(reason: detail))
    }

    private func unwrapSourceTimestamp(_ timestamp: UInt32?) -> Int64 {
        guard let timestamp else { return Int64(arrivalOrder) }
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

    private func scheduleRefill(after seconds: Double) {
        guard !refillScheduled else { return }
        refillScheduled = true
        feederQueue.asyncAfter(deadline: .now() + max(0.001, seconds)) { [weak self] in
            guard let self else { return }
            refillScheduled = false
            drain()
        }
    }

    private func noteEnqueue(pts: CMTime, lead: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        enqueueCount += 1
        if let previous = lastEnqueueAt, now > previous {
            appendBounded(now - previous, to: &enqueueIntervals)
        }
        if let previousPTS = lastPTS {
            appendBounded(CMTimeGetSeconds(CMTimeSubtract(pts, previousPTS)), to: &ptsIntervals)
        }
        lastEnqueueAt = now
        lastPTS = pts
        appendBounded(lead, to: &scheduledLeads)
    }

    private func logSummaryIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSummaryAt >= 5 else { return }
        lastSummaryAt = now
        logSummary(reason: "periodic")
    }

    private func logSummary(reason: String) {
        let enqueue = Self.stats(enqueueIntervals)
        let lead = Self.stats(scheduledLeads)
        let pts = Self.stats(ptsIntervals)
        ControlLiveLog.line(
            "timed-renderer: reason=\(reason) renderer_enqueue_count=\(enqueueCount) renderer_enqueue_interval_ms{\(enqueue)} renderer_ready_false_count=\(readyFalseCount) renderer_flush_count=\(flushCount) scheduled_lead_ms{\(lead)} pending_au_depth=\(pending.count) timed_renderer_start_count=\(startCount) timed_renderer_rebuffer_count=\(rebufferCount) timed_renderer_resync_count=\(resyncCount) sample_pts_interval_ms{\(pts)}")
        enqueueIntervals.removeAll(keepingCapacity: true)
        scheduledLeads.removeAll(keepingCapacity: true)
        ptsIntervals.removeAll(keepingCapacity: true)
    }

    private func appendBounded(_ value: Double, to values: inout [Double]) {
        values.append(value)
        if values.count > 4_096 { values.removeFirst(values.count - 4_096) }
    }

    private static func stats(_ seconds: [Double]) -> String {
        let milliseconds = seconds.filter { $0.isFinite }.map { $0 * 1_000 }.sorted()
        func percentile(_ fraction: Double) -> String {
            guard !milliseconds.isEmpty else { return "0.0" }
            let rank = max(
                0, min(milliseconds.count - 1, Int(ceil(fraction * Double(milliseconds.count))) - 1))
            return String(format: "%.1f", milliseconds[rank])
        }
        let minimum = String(format: "%.1f", milliseconds.first ?? 0)
        let maximum = String(format: "%.1f", milliseconds.last ?? 0)
        return "median=\(percentile(0.50)) p05=\(percentile(0.05)) p95=\(percentile(0.95)) p99=\(percentile(0.99)) min=\(minimum) max=\(maximum)"
    }
}
#endif
