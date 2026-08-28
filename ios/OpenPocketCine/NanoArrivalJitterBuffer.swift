import Foundation

/// Decode-before-playout queue for complete Nano AVC access units.
///
/// This follows DJIWidget's `DJIVideoPreviewSmoothHelper`: arrival cadence determines the nominal
/// frame interval and feedback keeps the oldest queued AU near the target delay. Camera source
/// timestamps remain diagnostic metadata only; a missing AU therefore does not create a matching
/// hole in the playout clock. Every received AU is released once, in arrival order.
final class NanoArrivalJitterBuffer: @unchecked Sendable {
    static let targetQueueDelaySeconds = 0.200
    static let estimationWindowSeconds = 2.0
    static let feedbackDeadbandSeconds = 0.010
    static let feedbackStepSeconds = 0.005
    static let usesFixedRatePacer = false

    static func djiRecordTimestamp(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.count >= 16, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1,
            bytes[3] == 0xff
        else { return nil }
        return UInt32(bytes[12]) | (UInt32(bytes[13]) << 8) | (UInt32(bytes[14]) << 16)
            | (UInt32(bytes[15]) << 24)
    }

    typealias Output = @Sendable (LivePacedAccessUnit) -> Void

    /// Pure policy helpers shared by the runtime queue and deterministic tests.
    struct Policy {
        /// Estimate encoded-frame cadence over the rolling arrival window. Trimming the tails once
        /// enough samples exist prevents a scheduling spike from selecting the playout rate without
        /// assuming 25 or 30 fps.
        static func nominalInterval(arrivalTimes: [TimeInterval]) -> TimeInterval? {
            guard arrivalTimes.count >= 2 else { return nil }
            let intervals = zip(arrivalTimes, arrivalTimes.dropFirst()).compactMap { pair in
                let value = pair.1 - pair.0
                return value >= 0.005 && value <= 0.250 && value.isFinite ? value : nil
            }.sorted()
            guard !intervals.isEmpty else { return nil }
            let trim = intervals.count >= 10 ? max(1, intervals.count / 10) : 0
            let kept = Array(intervals.dropFirst(trim).dropLast(trim))
            let values = kept.isEmpty ? intervals : kept
            return values.reduce(0, +) / Double(values.count)
        }

        static func releaseInterval(
            nominal: TimeInterval,
            queueDelay: TimeInterval,
            processingCost: TimeInterval = 0
        ) -> TimeInterval {
            var adjusted = nominal
            if queueDelay
                > NanoArrivalJitterBuffer.targetQueueDelaySeconds
                    + NanoArrivalJitterBuffer.feedbackDeadbandSeconds
            {
                adjusted -= NanoArrivalJitterBuffer.feedbackStepSeconds
            } else if queueDelay
                < NanoArrivalJitterBuffer.targetQueueDelaySeconds
                    - NanoArrivalJitterBuffer.feedbackDeadbandSeconds
            {
                adjusted += NanoArrivalJitterBuffer.feedbackStepSeconds
            }
            return max(0, adjusted - max(0, processingCost))
        }

        static func hasRefilled(queueDelay: TimeInterval) -> Bool {
            queueDelay + 0.000_5 >= NanoArrivalJitterBuffer.targetQueueDelaySeconds
        }

        /// Test model for playout cadence. Missing arrivals influence the rolling estimate but are
        /// never copied verbatim into output intervals as source-timestamp holes.
        static func simulatedReleaseIntervals(arrivalTimes: [TimeInterval]) -> [TimeInterval] {
            guard arrivalTimes.count >= 2, let nominal = nominalInterval(arrivalTimes: arrivalTimes)
            else { return [] }
            return Array(repeating: nominal, count: arrivalTimes.count - 1)
        }

        static func preservesOrder<T>(_ values: [T]) -> [T] { values }
    }

    private struct Entry: Sendable {
        let accessUnit: LivePacedAccessUnit
        let arrival: TimeInterval
    }

    private let queue = DispatchQueue(label: "opv.nano.arrival-jitter", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    private let output: Output

    // queue-owned state.
    private var pending: [Entry] = []
    private var arrivalSamples: [TimeInterval] = []
    private var nominalInterval: TimeInterval?
    private var playoutActive = false
    private var lastInputAt: TimeInterval?
    private var lastInputSourceTimestamp: UInt32?
    private var lastOutputAt: TimeInterval?
    private var stopped = false
    private var underflowCount = 0
    private var rebufferCount = 0
    private var lastSummaryAt: TimeInterval = 0
    private var inputIntervals: [TimeInterval] = []
    private var outputIntervals: [TimeInterval] = []
    private var sourceIntervals: [TimeInterval] = []
    private var queueDelays: [TimeInterval] = []

    init(output: @escaping Output) {
        self.output = output
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.releaseNext() }
        parkTimer()
        timer.resume()
        ControlLiveLog.line(
            "nano_smooth_decode=true target_queue_delay_ms=200 arrival_window_ms=2000 deadband_ms=10 feedback_step_ms=5 fixed_fps_pacer=false source_timestamp_scheduler=false")
    }

    /// Called directly with each complete AU on the datalink receive path.
    func push(_ accessUnit: LivePacedAccessUnit) {
        let arrival = ProcessInfo.processInfo.systemUptime
        #if OPENPOCKETCINE_DIAGNOSTICS
            LiveFramePacingDiagnostics.shared.noteAccessUnitBufferInput(
                accessUnit.trace, at: arrival)
        #endif
        queue.async { [weak self] in self?.accept(accessUnit, arrival: arrival) }
    }

    func reset(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            logSummary(reason: reason)
            clearQueue()
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
        if let timestamp = accessUnit.trace.sourceTimestamp {
            if let previous = lastInputSourceTimestamp {
                let delta = Int64(Int32(bitPattern: timestamp &- previous))
                if delta > 0 { appendBounded(TimeInterval(delta) / 1_000, to: &sourceIntervals) }
            }
            lastInputSourceTimestamp = timestamp
        }

        pending.append(Entry(accessUnit: accessUnit, arrival: arrival))
        arrivalSamples.append(arrival)
        let cutoff = arrival - Self.estimationWindowSeconds
        arrivalSamples.removeAll { $0 < cutoff }
        if let estimate = Policy.nominalInterval(arrivalTimes: arrivalSamples) {
            nominalInterval = estimate
        }

        if !playoutActive, let first = pending.first {
            timer.schedule(
                deadline: .now() + max(0, Self.targetQueueDelaySeconds - (arrival - first.arrival)),
                leeway: .milliseconds(1))
        }
        logSummaryIfNeeded(now: arrival)
    }

    private func releaseNext() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, let first = pending.first else {
            parkTimer()
            return
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let queueDelay = max(0, startedAt - first.arrival)
        if !playoutActive, !Policy.hasRefilled(queueDelay: queueDelay) {
            timer.schedule(
                deadline: .now() + max(0, Self.targetQueueDelaySeconds - queueDelay),
                leeway: .milliseconds(1))
            return
        }
        playoutActive = true
        pending.removeFirst()
        appendBounded(queueDelay, to: &queueDelays)
        if let previous = lastOutputAt, startedAt > previous {
            appendBounded(startedAt - previous, to: &outputIntervals)
        }
        lastOutputAt = startedAt
        #if OPENPOCKETCINE_DIAGNOSTICS
            LiveFramePacingDiagnostics.shared.noteAccessUnitBufferOutput(
                first.accessUnit.trace, at: startedAt)
        #endif

        output(first.accessUnit)
        let finishedAt = ProcessInfo.processInfo.systemUptime
        let processingCost = max(0, finishedAt - startedAt)

        guard !pending.isEmpty else {
            playoutActive = false
            underflowCount += 1
            rebufferCount += 1
            parkTimer()
            logSummaryIfNeeded(now: finishedAt)
            return
        }
        guard let nominalInterval else {
            playoutActive = false
            parkTimer()
            return
        }
        let sleep = Policy.releaseInterval(
            nominal: nominalInterval, queueDelay: queueDelay, processingCost: processingCost)
        timer.schedule(deadline: .now() + sleep, leeway: .milliseconds(1))
        logSummaryIfNeeded(now: finishedAt)
    }

    private func parkTimer() {
        timer.schedule(deadline: .now() + .seconds(86_400))
    }

    private func clearQueue() {
        pending.removeAll(keepingCapacity: true)
        arrivalSamples.removeAll(keepingCapacity: true)
        nominalInterval = nil
        playoutActive = false
        lastInputAt = nil
        lastInputSourceTimestamp = nil
        lastOutputAt = nil
        parkTimer()
    }

    private func logSummaryIfNeeded(now: TimeInterval) {
        guard now - lastSummaryAt >= 5 else { return }
        lastSummaryAt = now
        logSummary(reason: "periodic")
    }

    private func logSummary(reason: String) {
        ControlLiveLog.line(
            "nano-smooth-decode: reason=\(reason) arrival_interval_ms{\(Self.stats(inputIntervals))} release_interval_ms{\(Self.stats(outputIntervals))} queue_delay_ms{\(Self.stats(queueDelays))} buffer_depth=\(pending.count) nominal_interval_ms=\(String(format: "%.2f", (nominalInterval ?? 0) * 1_000)) underflow_count=\(underflowCount) rebuffer_count=\(rebufferCount) source_timestamp_interval_ms{\(Self.stats(sourceIntervals))}")
        inputIntervals.removeAll(keepingCapacity: true)
        outputIntervals.removeAll(keepingCapacity: true)
        sourceIntervals.removeAll(keepingCapacity: true)
        queueDelays.removeAll(keepingCapacity: true)
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
