#if OPENPOCKETCINE_DIAGNOSTICS
import Foundation

/// Test-only timing observer for the pktType-0x04 Window ACK pump.
///
/// This observer has its own lock and never participates in ACK generation, cursor selection,
/// socket writes, retransmission, or video assembly decisions.
final class NanoWindowAckDiagnostics: @unchecked Sendable {
    struct Summary: Equatable, Sendable {
        var timestamp: TimeInterval
        var packetType: UInt8
        var ackSequence: UInt16
        var windowSequence: UInt16
        var count: Int
        var durationMilliseconds: Double
        var rateHz: Double
        var intervalMedianMilliseconds: Double
        var intervalP95Milliseconds: Double
        var intervalP99Milliseconds: Double
        var intervalMaxMilliseconds: Double
        var gapsOver50Milliseconds: Int
        var gapsOver100Milliseconds: Int
        var gapsOver200Milliseconds: Int

        var logLine: String {
            "nano-window-ack-summary: monotonic_ms=\(Self.number(timestamp * 1_000)) pkt_type=0x\(String(format: "%02x", packetType)) ack_seq=\(ackSequence) window_seq=\(windowSequence) count=\(count) duration_ms=\(Self.number(durationMilliseconds)) rate_hz=\(Self.number(rateHz)) interval_med_ms=\(Self.number(intervalMedianMilliseconds)) interval_p95_ms=\(Self.number(intervalP95Milliseconds)) interval_p99_ms=\(Self.number(intervalP99Milliseconds)) interval_max_ms=\(Self.number(intervalMaxMilliseconds)) gt50ms=\(gapsOver50Milliseconds) gt100ms=\(gapsOver100Milliseconds) gt200ms=\(gapsOver200Milliseconds)"
        }

        private static func number(_ value: Double) -> String {
            String(format: "%.1f", value)
        }
    }

    struct Gap: Equatable, Sendable {
        var timestamp: TimeInterval
        var packetType: UInt8
        var intervalMilliseconds: Double
        var previousAckSequence: UInt16
        var currentAckSequence: UInt16
        var previousWindowSequence: UInt16
        var currentWindowSequence: UInt16

        var logLine: String {
            "nano-window-ack-gap: monotonic_ms=\(String(format: "%.1f", timestamp * 1_000)) pkt_type=0x\(String(format: "%02x", packetType)) interval_ms=\(String(format: "%.1f", intervalMilliseconds)) previous_ack_seq=\(previousAckSequence) current_ack_seq=\(currentAckSequence) previous_window_seq=\(previousWindowSequence) current_window_seq=\(currentWindowSequence)"
        }
    }

    struct Correlation: Equatable, Sendable {
        var lastAckAgeMilliseconds: Double?
        var ackRateLastSecondHz: Double
        var maxAckGapLastSecondMilliseconds: Double

        var logFields: String {
            let age = lastAckAgeMilliseconds.map { String(format: "%.1f", $0) } ?? "unknown"
            return "last_ack_age_ms=\(age) ack_rate_last_1s=\(String(format: "%.1f", ackRateLastSecondHz)) max_ack_gap_last_1s=\(String(format: "%.1f", maxAckGapLastSecondMilliseconds))"
        }
    }

    struct RecordResult: Equatable, Sendable {
        var gap: Gap?
        var summary: Summary?
    }

    static let shared = NanoWindowAckDiagnostics()
    static let summaryInterval: TimeInterval = 5
    static let gapThreshold: TimeInterval = 0.050

    private struct AckSample {
        var timestamp: TimeInterval
        var ackSequence: UInt16
        var windowSequence: UInt16
    }

    private struct IntervalSample {
        var endTimestamp: TimeInterval
        var milliseconds: Double
    }

    private let lock = NSLock()
    private var firstAckAt: TimeInterval?
    private var lastAck: AckSample?
    private var recentIntervals: [IntervalSample] = []
    private var summaryStartedAt: TimeInterval?
    private var summaryCount = 0
    private var summaryIntervals: [Double] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        firstAckAt = nil
        lastAck = nil
        recentIntervals.removeAll(keepingCapacity: true)
        summaryStartedAt = nil
        summaryCount = 0
        summaryIntervals.removeAll(keepingCapacity: true)
    }

    func noteAck(
        at timestamp: TimeInterval,
        packetType: UInt8 = 0x04,
        ackSequence: UInt16,
        windowSequence: UInt16
    ) -> RecordResult {
        lock.lock()
        defer { lock.unlock() }

        if firstAckAt == nil { firstAckAt = timestamp }
        if summaryStartedAt == nil { summaryStartedAt = timestamp }

        let sample = AckSample(
            timestamp: timestamp, ackSequence: ackSequence, windowSequence: windowSequence)
        let intervalMilliseconds = lastAck.map {
            max(0, timestamp - $0.timestamp) * 1_000
        }
        let gap: Gap?
        if let previous = lastAck, let intervalMilliseconds,
            intervalMilliseconds >= Self.gapThreshold * 1_000
        {
            gap = Gap(
                timestamp: timestamp, packetType: packetType,
                intervalMilliseconds: intervalMilliseconds,
                previousAckSequence: previous.ackSequence, currentAckSequence: ackSequence,
                previousWindowSequence: previous.windowSequence,
                currentWindowSequence: windowSequence)
        } else {
            gap = nil
        }
        lastAck = sample

        summaryCount += 1
        if let intervalMilliseconds {
            let interval = IntervalSample(
                endTimestamp: timestamp, milliseconds: intervalMilliseconds)
            recentIntervals.append(interval)
            summaryIntervals.append(intervalMilliseconds)
        }
        trimRecent(at: timestamp)

        let summary: Summary?
        if let startedAt = summaryStartedAt,
            timestamp - startedAt >= Self.summaryInterval
        {
            let duration = timestamp - startedAt
            let sorted = summaryIntervals.sorted()
            summary = Summary(
                timestamp: timestamp, packetType: packetType, ackSequence: ackSequence,
                windowSequence: windowSequence, count: summaryCount,
                durationMilliseconds: duration * 1_000,
                rateHz: duration > 0 ? Double(summaryIntervals.count) / duration : 0,
                intervalMedianMilliseconds: Self.percentile(sorted, 0.50),
                intervalP95Milliseconds: Self.percentile(sorted, 0.95),
                intervalP99Milliseconds: Self.percentile(sorted, 0.99),
                intervalMaxMilliseconds: sorted.last ?? 0,
                gapsOver50Milliseconds: summaryIntervals.filter { $0 >= 50 }.count,
                gapsOver100Milliseconds: summaryIntervals.filter { $0 >= 100 }.count,
                gapsOver200Milliseconds: summaryIntervals.filter { $0 >= 200 }.count)
            summaryStartedAt = timestamp
            summaryCount = 0
            summaryIntervals.removeAll(keepingCapacity: true)
        } else {
            summary = nil
        }
        return RecordResult(gap: gap, summary: summary)
    }

    func correlation(at timestamp: TimeInterval) -> Correlation {
        lock.lock()
        defer { lock.unlock() }
        trimRecent(at: timestamp)

        let age = lastAck.map { max(0, timestamp - $0.timestamp) * 1_000 }
        let observationDuration = firstAckAt.map { min(1, max(0, timestamp - $0)) } ?? 0
        let rate = observationDuration > 0
            ? Double(recentIntervals.count) / observationDuration : 0
        let completedGap = recentIntervals.map(\.milliseconds).max() ?? 0
        return Correlation(
            lastAckAgeMilliseconds: age, ackRateLastSecondHz: rate,
            maxAckGapLastSecondMilliseconds: max(completedGap, age ?? 0))
    }

    private func trimRecent(at timestamp: TimeInterval) {
        let cutoff = timestamp - 1
        recentIntervals.removeAll { $0.endTimestamp < cutoff - 0.000_000_001 }
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(0, min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1))
        return sorted[rank]
    }
}
#endif
