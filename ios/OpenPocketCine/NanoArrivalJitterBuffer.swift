#if OPENPOCKETCINE_DIAGNOSTICS
import Foundation

/// Test-only arrival-jitter buffer for complete Nano AVC access units.
///
/// The buffer restores the camera's own millisecond timestamp cadence after Wi-Fi arrival jitter.
/// It does not synthesize frames, normalize to 30 fps, or change the existing decoder/presentation
/// path. Each input AU is released exactly once to DatalinkDriver's production-shaped callback.
final class NanoArrivalJitterBuffer: @unchecked Sendable {
    static let delaySeconds = 0.200
    static let usesFixedRatePacer = false

    typealias Output = @Sendable (LivePacedAccessUnit) -> Void

    struct Schedule: Equatable, Sendable {
        let sourceBaseTimestamp: UInt32

        func offsetSeconds(for timestamp: UInt32) -> TimeInterval {
            TimeInterval(Self.deltaMilliseconds(from: sourceBaseTimestamp, to: timestamp)) / 1_000
        }

        static func outputIntervalsMilliseconds(for timestamps: [UInt32]) -> [Int64] {
            zip(timestamps, timestamps.dropFirst()).map {
                deltaMilliseconds(from: $0.0, to: $0.1)
            }
        }

        static func orderedIndices(for timestamps: [UInt32]) -> [Int] {
            guard let first = timestamps.first else { return [] }
            return timestamps.enumerated().sorted {
                let left = deltaMilliseconds(from: first, to: $0.element)
                let right = deltaMilliseconds(from: first, to: $1.element)
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.offset)
        }

        private static func deltaMilliseconds(from: UInt32, to: UInt32) -> Int64 {
            Int64(Int32(bitPattern: to &- from))
        }
    }

    private struct Entry: Sendable {
        let accessUnit: LivePacedAccessUnit
        let sourceOrder: Int64
        let arrivalOrder: UInt64
    }

    private let queue = DispatchQueue(label: "opv.nano.arrival-jitter", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    private let output: Output

    // queue-owned state.
    private var pending: [Entry] = []
    private var sourceAnchorRaw: UInt32?
    private var sourceAnchorUnwrapped: Int64?
    private var sourceBaseOrder: Int64?
    private var hostBaseTime: TimeInterval?
    private var nextArrivalOrder: UInt64 = 0
    private var lastInputAt: TimeInterval?
    private var lastInputSourceOrder: Int64?
    private var lastOutputAt: TimeInterval?
    private var lastOutputSourceOrder: Int64?
    private var stopped = false
    private var underflowCount = 0
    private var rebufferCount = 0
    private var lastSummaryAt: TimeInterval = 0
    private var inputIntervals: [TimeInterval] = []
    private var outputIntervals: [TimeInterval] = []
    private var sourceIntervals: [TimeInterval] = []

    init(output: @escaping Output) {
        self.output = output
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.releaseNext() }
        timer.schedule(deadline: .now() + .seconds(86_400))
        timer.resume()
        ControlLiveLog.line(
            "nano_test_mode=arrival_jitter_buffer_only jitter_buffer_delay_ms=200 fixed_fps_pacer=false timed_renderer=false production_presentation=true")
    }

    /// Called directly with each complete AU on the datalink receive path.
    func push(_ accessUnit: LivePacedAccessUnit) {
        let arrival = ProcessInfo.processInfo.systemUptime
        LiveFramePacingDiagnostics.shared.noteAccessUnitBufferInput(accessUnit.trace, at: arrival)
        queue.async { [weak self] in self?.accept(accessUnit, arrival: arrival) }
    }

    func reset(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            logSummary(reason: reason)
            clearTimeline()
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            logSummary(reason: "stop")
            pending.removeAll(keepingCapacity: false)
            timer.cancel()
        }
    }

    private func accept(_ accessUnit: LivePacedAccessUnit, arrival: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        if let previous = lastInputAt, arrival > previous {
            appendBounded(arrival - previous, to: &inputIntervals)
        }
        lastInputAt = arrival
        nextArrivalOrder &+= 1
        let sourceOrder = unwrap(accessUnit.trace.sourceTimestamp)

        if let previous = lastInputSourceOrder, sourceOrder > previous {
            appendBounded(TimeInterval(sourceOrder - previous) / 1_000, to: &sourceIntervals)
        }
        lastInputSourceOrder = sourceOrder

        if sourceBaseOrder == nil || hostBaseTime == nil {
            anchor(sourceOrder: sourceOrder, now: arrival)
        } else if pending.isEmpty, lastOutputAt != nil,
            releaseTime(for: sourceOrder) <= arrival
        {
            // The scheduled reserve is truly exhausted. Keep Production's last displayed frame,
            // collect a new 200 ms reserve, and restart from this AU without decoder intervention.
            underflowCount += 1
            rebufferCount += 1
            anchor(sourceOrder: sourceOrder, now: arrival)
        }

        pending.append(
            Entry(
                accessUnit: accessUnit, sourceOrder: sourceOrder,
                arrivalOrder: nextArrivalOrder))
        pending.sort {
            $0.sourceOrder == $1.sourceOrder
                ? $0.arrivalOrder < $1.arrivalOrder : $0.sourceOrder < $1.sourceOrder
        }
        scheduleNext(now: arrival)
        logSummaryIfNeeded(now: arrival)
    }

    private func releaseNext() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, let first = pending.first else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let due = releaseTime(for: first.sourceOrder)
        guard due <= now + 0.000_5 else {
            scheduleNext(now: now)
            return
        }
        pending.removeFirst()
        if let previous = lastOutputAt, now > previous {
            appendBounded(now - previous, to: &outputIntervals)
        }
        lastOutputAt = now
        lastOutputSourceOrder = first.sourceOrder
        LiveFramePacingDiagnostics.shared.noteAccessUnitBufferOutput(first.accessUnit.trace, at: now)
        output(first.accessUnit)
        scheduleNext(now: now)
        logSummaryIfNeeded(now: now)
    }

    private func scheduleNext(now: TimeInterval) {
        guard !stopped, let first = pending.first else {
            timer.schedule(deadline: .now() + .seconds(86_400))
            return
        }
        let delay = max(0, releaseTime(for: first.sourceOrder) - now)
        timer.schedule(
            deadline: .now() + delay,
            leeway: .milliseconds(1))
    }

    private func anchor(sourceOrder: Int64, now: TimeInterval) {
        sourceBaseOrder = sourceOrder
        hostBaseTime = now + Self.delaySeconds
    }

    private func releaseTime(for sourceOrder: Int64) -> TimeInterval {
        guard let sourceBaseOrder, let hostBaseTime else {
            return ProcessInfo.processInfo.systemUptime + Self.delaySeconds
        }
        return hostBaseTime + TimeInterval(sourceOrder - sourceBaseOrder) / 1_000
    }

    private func unwrap(_ timestamp: UInt32?) -> Int64 {
        guard let timestamp else {
            return (pending.last?.sourceOrder ?? lastOutputSourceOrder ?? 0) + 33
        }
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

    private func clearTimeline() {
        pending.removeAll(keepingCapacity: true)
        sourceAnchorRaw = nil
        sourceAnchorUnwrapped = nil
        sourceBaseOrder = nil
        hostBaseTime = nil
        lastInputAt = nil
        lastInputSourceOrder = nil
        lastOutputAt = nil
        lastOutputSourceOrder = nil
        timer.schedule(deadline: .now() + .seconds(86_400))
    }

    private func logSummaryIfNeeded(now: TimeInterval) {
        guard now - lastSummaryAt >= 5 else { return }
        lastSummaryAt = now
        logSummary(reason: "periodic")
    }

    private func logSummary(reason: String) {
        let span: Double
        if let first = pending.first, let last = pending.last {
            span = Double(max(0, last.sourceOrder - first.sourceOrder))
        } else {
            span = 0
        }
        ControlLiveLog.line(
            "arrival-jitter-buffer: reason=\(reason) arrival_jitter_input_interval_ms{\(Self.stats(inputIntervals))} jitter_buffer_output_interval_ms{\(Self.stats(outputIntervals))} buffer_depth=\(pending.count) buffer_span_ms=\(String(format: "%.1f", span)) underflow_count=\(underflowCount) rebuffer_count=\(rebufferCount) source_timestamp_interval_ms{\(Self.stats(sourceIntervals))}")
        inputIntervals.removeAll(keepingCapacity: true)
        outputIntervals.removeAll(keepingCapacity: true)
        sourceIntervals.removeAll(keepingCapacity: true)
    }

    private func appendBounded(_ value: TimeInterval, to values: inout [TimeInterval]) {
        values.append(value)
        if values.count > 4_096 { values.removeFirst(values.count - 4_096) }
    }

    private static func stats(_ seconds: [TimeInterval]) -> String {
        let values = seconds.filter { $0 > 0 && $0.isFinite }.map { $0 * 1_000 }.sorted()
        func value(_ fraction: Double) -> String {
            guard !values.isEmpty else { return "0.0" }
            let rank = max(0, min(values.count - 1, Int(ceil(fraction * Double(values.count))) - 1))
            return String(format: "%.1f", values[rank])
        }
        return "median=\(value(0.50)) p95=\(value(0.95)) p99=\(value(0.99)) max=\(String(format: "%.1f", values.last ?? 0))"
    }
}
#endif
