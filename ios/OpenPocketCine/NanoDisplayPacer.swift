#if OPENPOCKETCINE_DIAGNOSTICS
import CoreVideo
import Foundation
import OpenPocketViewCore
import QuartzCore
import UIKit
import os

/// Lock-protected decoded-frame storage written directly by the VideoToolbox callback.
/// CVPixelBuffer is strongly retained by `Frame` while it is inside the bounded queue.
final class NanoDisplayFrameBuffer: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let imageBuffer: CVPixelBuffer
        let effects: LiveImageEffects
        let transfer: MonitorTransfer
        let trace: LiveFrameTrace?
        fileprivate let sourceOrder: Int64
        fileprivate let arrivalOrder: UInt64
    }

    struct Metrics {
        let inputCount: Int
        let depth: Int
        let overflowDropCount: Int
        let lateSourceDropCount: Int
        let vtCallbackIntervals: [TimeInterval]
        let enqueueDurations: [TimeInterval]
        let inputIntervals: [TimeInterval]
    }

    private struct State {
        var entries: [Frame] = []
        var sourceAnchorRaw: UInt32?
        var sourceAnchorUnwrapped: Int64?
        var lastPresentedSourceOrder: Int64?
        var nextArrivalOrder: UInt64 = 0
        var inputCount = 0
        var overflowDropCount = 0
        var lateSourceDropCount = 0
        var lastVTCallbackAt: TimeInterval?
        var lastInputAt: TimeInterval?
        var vtCallbackIntervals: [TimeInterval] = []
        var enqueueDurations: [TimeInterval] = []
        var inputIntervals: [TimeInterval] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func push(
        imageBuffer: CVPixelBuffer,
        effects: LiveImageEffects,
        transfer: MonitorTransfer,
        trace: LiveFrameTrace?,
        callbackAt: TimeInterval
    ) {
        lock.withLock { state in
            state.inputCount += 1
            if let previous = state.lastVTCallbackAt, callbackAt > previous {
                Self.appendBounded(callbackAt - previous, to: &state.vtCallbackIntervals)
            }
            state.lastVTCallbackAt = callbackAt
            state.nextArrivalOrder &+= 1
            let order = Self.sourceOrder(
                for: trace?.sourceTimestamp,
                state: &state)
            if let presented = state.lastPresentedSourceOrder, order <= presented {
                state.lateSourceDropCount += 1
                Self.noteEnqueueFinished(callbackAt: callbackAt, state: &state)
                return
            }
            state.entries.append(
                Frame(
                    imageBuffer: imageBuffer,
                    effects: effects,
                    transfer: transfer,
                    trace: trace,
                    sourceOrder: order,
                    arrivalOrder: state.nextArrivalOrder))
            state.entries.sort {
                if $0.sourceOrder == $1.sourceOrder {
                    return $0.arrivalOrder < $1.arrivalOrder
                }
                return $0.sourceOrder < $1.sourceOrder
            }
            while state.entries.count > NanoDisplayPacer.maximumDepth {
                state.entries.removeFirst()
                state.overflowDropCount += 1
            }
            Self.noteEnqueueFinished(callbackAt: callbackAt, state: &state)
        }
    }

    func popFirst() -> Frame? {
        lock.withLock { state in
            guard !state.entries.isEmpty else { return nil }
            let frame = state.entries.removeFirst()
            state.lastPresentedSourceOrder = frame.sourceOrder
            return frame
        }
    }

    func depth() -> Int { lock.withLock { $0.entries.count } }

    func reset() {
        lock.withLock { state in
            state = State()
        }
    }

    func takeMetrics() -> Metrics {
        lock.withLock { state in
            let metrics = Metrics(
                inputCount: state.inputCount,
                depth: state.entries.count,
                overflowDropCount: state.overflowDropCount,
                lateSourceDropCount: state.lateSourceDropCount,
                vtCallbackIntervals: state.vtCallbackIntervals,
                enqueueDurations: state.enqueueDurations,
                inputIntervals: state.inputIntervals)
            state.vtCallbackIntervals.removeAll(keepingCapacity: true)
            state.enqueueDurations.removeAll(keepingCapacity: true)
            state.inputIntervals.removeAll(keepingCapacity: true)
            return metrics
        }
    }

    private static func noteEnqueueFinished(callbackAt: TimeInterval, state: inout State) {
        let finishedAt = ProcessInfo.processInfo.systemUptime
        appendBounded(max(0, finishedAt - callbackAt), to: &state.enqueueDurations)
        if let previous = state.lastInputAt, finishedAt > previous {
            appendBounded(finishedAt - previous, to: &state.inputIntervals)
        }
        state.lastInputAt = finishedAt
    }

    private static func sourceOrder(for timestamp: UInt32?, state: inout State) -> Int64 {
        guard let timestamp else {
            return (state.entries.last?.sourceOrder ?? state.lastPresentedSourceOrder ?? 0) + 1
        }
        guard let anchorRaw = state.sourceAnchorRaw,
            let anchor = state.sourceAnchorUnwrapped
        else {
            state.sourceAnchorRaw = timestamp
            state.sourceAnchorUnwrapped = Int64(timestamp)
            return Int64(timestamp)
        }
        let delta = Int64(Int32(bitPattern: timestamp &- anchorRaw))
        let unwrapped = anchor + delta
        if delta > 0 {
            state.sourceAnchorRaw = timestamp
            state.sourceAnchorUnwrapped = unwrapped
        }
        return unwrapped
    }

    private static func appendBounded(_ value: TimeInterval, to values: inout [TimeInterval]) {
        values.append(value)
        if values.count > 4_096 {
            values.removeFirst(values.count - 4_096)
        }
    }
}

/// Test-target-only presentation clock for already-decoded Nano frames.
/// Storage input is nonisolated; only CADisplayLink pop and UIKit presentation use MainActor.
@MainActor
final class NanoDisplayPacer: NSObject, @unchecked Sendable {
    nonisolated static let framesPerSecond = 30.0
    nonisolated static let cadence = 1.0 / framesPerSecond
    nonisolated static let targetDepth = 24
    nonisolated static let maximumDepth = 45

    nonisolated private let storage = NanoDisplayFrameBuffer()
    var onPresent: ((NanoDisplayFrameBuffer.Frame) -> Void)?

    private var displayLink: CADisplayLink?
    private var nextPresentationTime: CFTimeInterval?
    private var outputCount = 0
    private var underflowCount = 0
    private var rebufferCount = 0
    private var rebufferStartedAt: CFTimeInterval?
    private var lastRebufferDurationMs = 0.0
    private var outputIntervals: [TimeInterval] = []
    private var displayTickIntervals: [TimeInterval] = []
    private var lastOutputAt: CFTimeInterval?
    private var lastDisplayTickAt: CFTimeInterval?
    private var lastLogAt = CACurrentMediaTime()

    override init() {
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(displayTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(Self.framesPerSecond),
            maximum: Float(Self.framesPerSecond),
            preferred: Float(Self.framesPerSecond))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Called synchronously inside the VT output callback. No Task or MainActor hop is performed.
    nonisolated func enqueueFromVideoToolbox(
        imageBuffer: CVPixelBuffer,
        effects: LiveImageEffects,
        transfer: MonitorTransfer,
        trace: LiveFrameTrace?,
        callbackAt: TimeInterval
    ) {
        storage.push(
            imageBuffer: imageBuffer,
            effects: effects,
            transfer: transfer,
            trace: trace,
            callbackAt: callbackAt)
    }

    func reset(reason: String) {
        logSummary(reason: reason)
        storage.reset()
        nextPresentationTime = nil
        lastOutputAt = nil
        lastDisplayTickAt = nil
        outputIntervals.removeAll(keepingCapacity: true)
        displayTickIntervals.removeAll(keepingCapacity: true)
        outputCount = 0
        underflowCount = 0
        rebufferCount = 0
        rebufferStartedAt = nil
        lastRebufferDurationMs = 0
        lastLogAt = CACurrentMediaTime()
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        if let previous = lastDisplayTickAt, now > previous {
            appendBounded(now - previous, to: &displayTickIntervals)
        }
        lastDisplayTickAt = now

        if nextPresentationTime == nil, storage.depth() >= Self.targetDepth {
            if let startedAt = rebufferStartedAt {
                lastRebufferDurationMs = max(0, now - startedAt) * 1_000
                rebufferStartedAt = nil
            }
            // The current display tick presents frame one at about 800 ms initial depth.
            nextPresentationTime = now
        }

        if let deadline = nextPresentationTime, now + 0.001 >= deadline {
            if let frame = storage.popFirst() {
                onPresent?(frame)
                outputCount += 1
                if let previous = lastOutputAt, now > previous {
                    appendBounded(now - previous, to: &outputIntervals)
                }
                lastOutputAt = now
                // Never catch up: one output maximum, next deadline anchored to this display tick.
                nextPresentationTime = now + Self.cadence
            } else {
                // AVSampleBufferDisplayLayer holds the last frame while 24 frames are rebuffered.
                underflowCount += 1
                rebufferCount += 1
                rebufferStartedAt = now
                nextPresentationTime = nil
            }
        }
        logIfNeeded(now: now)
    }

    private func logIfNeeded(now: CFTimeInterval) {
        guard now - lastLogAt >= 5 else { return }
        lastLogAt = now
        logSummary(reason: "periodic")
    }

    private func logSummary(reason: String) {
        let metrics = storage.takeMetrics()
        let vtCallbackStats = intervalStats(metrics.vtCallbackIntervals)
        let enqueueStats = intervalStats(metrics.enqueueDurations)
        let inputStats = intervalStats(metrics.inputIntervals)
        let displayTickStats = intervalStats(displayTickIntervals)
        let outputStats = intervalStats(outputIntervals)
        displayTickIntervals.removeAll(keepingCapacity: true)
        outputIntervals.removeAll(keepingCapacity: true)
        let fields = [
            "reason=\(reason)",
            "pacer_input=\(metrics.inputCount)",
            "pacer_output=\(outputCount)",
            "target_buffer_frames=\(Self.targetDepth)",
            "max_buffer_frames=\(Self.maximumDepth)",
            "buffer_depth=\(metrics.depth)",
            "current_buffer_duration_ms=\(bufferDurationMs(metrics.depth))",
            "underflow_count=\(underflowCount)",
            "overflow_drop_count=\(metrics.overflowDropCount)",
            "rebuffer_count=\(rebufferCount)",
            "rebuffer_duration_ms=\(rebufferDurationMs)",
            "late_source_drop_count=\(metrics.lateSourceDropCount)",
            "vt_callback_interval_ms{\(vtCallbackStats)}",
            "vt_to_buffer_enqueue_ms{\(enqueueStats)}",
            "buffer_input_interval_ms{\(inputStats)}",
            "display_tick_interval_ms{\(displayTickStats)}",
            "pacer_output_interval_ms{\(outputStats)}",
        ]
        ControlLiveLog.line("pacer: \(fields.joined(separator: " "))")
    }

    private func bufferDurationMs(_ depth: Int) -> String {
        String(format: "%.1f", Double(depth) * Self.cadence * 1_000)
    }

    private var rebufferDurationMs: String {
        let duration = rebufferStartedAt.map { max(0, CACurrentMediaTime() - $0) * 1_000 }
            ?? lastRebufferDurationMs
        return String(format: "%.1f", duration)
    }

    private func intervalStats(_ values: [TimeInterval]) -> String {
        let sorted = values.sorted()
        return [
            "median=\(metric(sorted, 0.50))",
            "p95=\(metric(sorted, 0.95))",
            "p99=\(metric(sorted, 0.99))",
            "max=\(maximum(sorted))",
        ].joined(separator: " ")
    }

    private func metric(_ sorted: [TimeInterval], _ percentile: Double) -> String {
        guard !sorted.isEmpty else { return "0.0" }
        let rank = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * percentile)) - 1))
        return String(format: "%.1f", sorted[rank] * 1_000)
    }

    private func maximum(_ sorted: [TimeInterval]) -> String {
        String(format: "%.1f", (sorted.last ?? 0) * 1_000)
    }

    private func appendBounded(_ value: TimeInterval, to values: inout [TimeInterval]) {
        values.append(value)
        if values.count > 4_096 {
            values.removeFirst(values.count - 4_096)
        }
    }
}
#endif
