#if OPENPOCKETCINE_DIAGNOSTICS
import Foundation
import OpenPocketViewCore
import os

/// Test-target-only pacing for complete, compressed Nano AVC access units.
///
/// The receive queue pushes synchronously into lock-protected storage. A private 30 Hz timer removes
/// at most one AU per tick, then the configured output hops to the actor required by HevcDecoder.
/// Production does not compile this type.
final class NanoAccessUnitPacer: @unchecked Sendable {
    static let framesPerSecond = 30.0
    static let cadence = 1.0 / framesPerSecond
    static let targetDepth = 12
    static let maximumDepth = 60

    typealias Output = @Sendable (LivePacedAccessUnit) -> Void

    struct Metrics {
        let inputCount: Int
        let outputCount: Int
        let depth: Int
        let underflowCount: Int
        let overflowCount: Int
        let rebufferCount: Int
        let inputIntervals: [TimeInterval]
        let outputIntervals: [TimeInterval]
    }

    private struct Entry: Sendable {
        let accessUnit: LivePacedAccessUnit
        let sourceOrder: Int64
        let arrivalOrder: UInt64
    }

    private struct State {
        var enabled = false
        var output: Output?
        var entries: [Entry] = []
        var sourceAnchorRaw: UInt32?
        var sourceAnchorUnwrapped: Int64?
        var nextArrivalOrder: UInt64 = 0
        var started = false
        var awaitingIDRAfterOverflow = false
        var deliveryInFlight = false
        var inputCount = 0
        var outputCount = 0
        var underflowCount = 0
        var overflowCount = 0
        var rebufferCount = 0
        var lastInputAt: TimeInterval?
        var lastOutputAt: TimeInterval?
        var lastSummaryAt: TimeInterval = 0
        var inputIntervals: [TimeInterval] = []
        var outputIntervals: [TimeInterval] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let timerQueue = DispatchQueue(label: "opv.nano.au-pacer", qos: .userInteractive)
    private let timer: DispatchSourceTimer

    init() {
        timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now(), repeating: Self.cadence,
            leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    deinit { timer.cancel() }

    func configure(output: @escaping Output) {
        lock.withLock { state in
            state = State()
            state.enabled = true
            state.output = output
        }
        ControlLiveLog.line(
            "au-pacer: configured target_au=\(Self.targetDepth) max_au=\(Self.maximumDepth) fps=30")
    }

    func disable(reason: String) {
        logSummary(reason: reason)
        lock.withLock { $0 = State() }
    }

    func reset(reason: String) {
        logSummary(reason: reason)
        lock.withLock { state in
            let enabled = state.enabled
            let output = state.output
            state = State()
            state.enabled = enabled
            state.output = output
        }
    }

    var isEnabled: Bool { lock.withLock { $0.enabled } }

    /// Called on the datalink receive queue immediately after a complete AVC AU is reconstructed.
    func push(_ accessUnit: LivePacedAccessUnit) {
        let now = ProcessInfo.processInfo.systemUptime
        LiveFramePacingDiagnostics.shared.noteAccessUnitBufferInput(accessUnit.trace, at: now)
        lock.withLock { state in
            guard state.enabled else { return }
            state.inputCount += 1
            if let previous = state.lastInputAt, now > previous {
                Self.appendBounded(now - previous, to: &state.inputIntervals)
            }
            state.lastInputAt = now
            state.nextArrivalOrder &+= 1
            let idr = Self.isIDR(accessUnit.bytes)

            if state.awaitingIDRAfterOverflow {
                guard idr else { return }
                // Resume only from a decodable boundary; never drop one arbitrary P-frame.
                state.entries.removeAll(keepingCapacity: true)
                state.sourceAnchorRaw = nil
                state.sourceAnchorUnwrapped = nil
                state.started = false
                state.awaitingIDRAfterOverflow = false
                state.rebufferCount += 1
            }

            if state.entries.count >= Self.maximumDepth {
                state.overflowCount += 1
                state.started = false
                state.entries.removeAll(keepingCapacity: true)
                state.sourceAnchorRaw = nil
                state.sourceAnchorUnwrapped = nil
                state.rebufferCount += 1
                if !idr {
                    state.awaitingIDRAfterOverflow = true
                    // The AU that exposed overflow is not emitted. A clean IDR starts the next GOP.
                    return
                }
            }

            let sourceOrder = Self.sourceOrder(
                for: accessUnit.trace.sourceTimestamp, state: &state)
            state.entries.append(
                Entry(
                    accessUnit: accessUnit,
                    sourceOrder: sourceOrder,
                    arrivalOrder: state.nextArrivalOrder))
            state.entries.sort {
                if $0.sourceOrder == $1.sourceOrder {
                    return $0.arrivalOrder < $1.arrivalOrder
                }
                return $0.sourceOrder < $1.sourceOrder
            }
            if !state.started, state.entries.count >= Self.targetDepth {
                state.started = true
            }
        }
    }

    func takeMetrics() -> Metrics {
        lock.withLock { state in
            let metrics = Metrics(
                inputCount: state.inputCount,
                outputCount: state.outputCount,
                depth: state.entries.count,
                underflowCount: state.underflowCount,
                overflowCount: state.overflowCount,
                rebufferCount: state.rebufferCount,
                inputIntervals: state.inputIntervals,
                outputIntervals: state.outputIntervals)
            state.inputIntervals.removeAll(keepingCapacity: true)
            state.outputIntervals.removeAll(keepingCapacity: true)
            return metrics
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        var shouldLog = false
        let delivery: (Output, LivePacedAccessUnit)? = lock.withLock { state in
            guard state.enabled else { return nil }
            if now - state.lastSummaryAt >= 5 {
                state.lastSummaryAt = now
                shouldLog = true
            }
            guard state.started, !state.awaitingIDRAfterOverflow, !state.deliveryInFlight else {
                return nil
            }
            guard !state.entries.isEmpty else {
                state.started = false
                state.underflowCount += 1
                state.rebufferCount += 1
                return nil
            }
            let entry = state.entries.removeFirst()
            state.outputCount += 1
            if let previous = state.lastOutputAt, now > previous {
                Self.appendBounded(now - previous, to: &state.outputIntervals)
            }
            state.lastOutputAt = now
            guard let output = state.output else { return nil }
            state.deliveryInFlight = true
            return (output, entry.accessUnit)
        }
        if let (output, accessUnit) = delivery {
            LiveFramePacingDiagnostics.shared.noteAccessUnitBufferOutput(
                accessUnit.trace, at: now)
            output(accessUnit)
        }
        if shouldLog { logSummary(reason: "periodic") }
    }

    func deliveryCompleted() {
        lock.withLock { $0.deliveryInFlight = false }
    }

    private func logSummary(reason: String) {
        let metrics = takeMetrics()
        let input = Self.intervalStats(metrics.inputIntervals)
        let output = Self.intervalStats(metrics.outputIntervals)
        ControlLiveLog.line(
            "au-pacer: reason=\(reason) au_buffer_input=\(metrics.inputCount) au_buffer_output=\(metrics.outputCount) au_buffer_depth=\(metrics.depth) au_underflow_count=\(metrics.underflowCount) au_overflow_count=\(metrics.overflowCount) rebuffer_count=\(metrics.rebufferCount) au_buffer_input_interval_ms{\(input)} au_buffer_output_interval_ms{\(output)}")
    }

    private static func sourceOrder(for timestamp: UInt32?, state: inout State) -> Int64 {
        guard let timestamp else {
            return (state.entries.last?.sourceOrder ?? 0) + 1
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

    private static func isIDR(_ bytes: [UInt8]) -> Bool {
        Hevc.nalUnits(bytes).contains { nal in
            !nal.isEmpty && Avc.nalType(nal[0]) == Avc.idr
        }
    }

    private static func appendBounded(_ value: TimeInterval, to values: inout [TimeInterval]) {
        values.append(value)
        if values.count > 4_096 { values.removeFirst(values.count - 4_096) }
    }

    private static func intervalStats(_ values: [TimeInterval]) -> String {
        let sorted = values.sorted()
        func metric(_ fraction: Double) -> String {
            guard !sorted.isEmpty else { return "0.0" }
            let rank = max(0, min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1))
            return String(format: "%.1f", sorted[rank] * 1_000)
        }
        return "median=\(metric(0.50)) p95=\(metric(0.95)) p99=\(metric(0.99)) max=\(String(format: "%.1f", (sorted.last ?? 0) * 1_000))"
    }
}
#endif
