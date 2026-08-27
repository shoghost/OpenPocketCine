#if OPENPOCKETCINE_DIAGNOSTICS
import Foundation
import QuartzCore
import UIKit

/// Test-target-only presentation smoother for decoded Nano frames.
///
/// VideoToolbox and the network pipeline run at full speed. This queue starts only after three
/// decoded frames are available, then releases at most one frame per display-clock cadence.
/// Entries contain independent CVPixelBuffer-backed presentation work, so dropping an old entry
/// cannot break AVC reference decoding.
@MainActor
final class NanoDisplayPacer: NSObject {
    static let framesPerSecond = 30.0
    static let cadence = 1.0 / framesPerSecond
    static let targetDepth = 3
    static let maximumDepth = 6

    private struct Entry {
        let sourceOrder: Int64
        let arrivalOrder: UInt64
        let present: () -> Void
    }

    private var entries: [Entry] = []
    private var displayLink: CADisplayLink?
    private var nextPresentationTime: CFTimeInterval?
    private var sourceAnchorRaw: UInt32?
    private var sourceAnchorUnwrapped: Int64?
    private var lastPresentedSourceOrder: Int64?
    private var nextArrivalOrder: UInt64 = 0
    private var inputCount = 0
    private var outputCount = 0
    private var underflowCount = 0
    private var overflowDropCount = 0
    private var lateSourceDropCount = 0
    private var inputIntervals: [TimeInterval] = []
    private var outputIntervals: [TimeInterval] = []
    private var lastInputAt: CFTimeInterval?
    private var lastOutputAt: CFTimeInterval?
    private var lastLogAt = CACurrentMediaTime()

    func enqueue(sourceTimestamp: UInt32?, present: @escaping () -> Void) {
        ensureDisplayLink()
        let now = CACurrentMediaTime()
        inputCount += 1
        if let previous = lastInputAt, now > previous {
            inputIntervals.append(now - previous)
            if inputIntervals.count > 4_096 {
                inputIntervals.removeFirst(inputIntervals.count - 4_096)
            }
        }
        lastInputAt = now
        nextArrivalOrder &+= 1
        let order = sourceOrder(for: sourceTimestamp)
        if let presented = lastPresentedSourceOrder, order <= presented {
            lateSourceDropCount += 1
            logIfNeeded(now: now)
            return
        }
        let entry = Entry(
            sourceOrder: order,
            arrivalOrder: nextArrivalOrder,
            present: present)
        entries.append(entry)
        entries.sort {
            if $0.sourceOrder == $1.sourceOrder { return $0.arrivalOrder < $1.arrivalOrder }
            return $0.sourceOrder < $1.sourceOrder
        }

        while entries.count > Self.maximumDepth {
            entries.removeFirst()
            overflowDropCount += 1
        }

        if nextPresentationTime == nil, entries.count >= Self.targetDepth {
            // Three decoded frames plus one cadence produces the requested ~90–100 ms reservoir.
            nextPresentationTime = now + Self.cadence
        }
        displayLink?.isPaused = false
        logIfNeeded(now: now)
    }

    func reset(reason: String) {
        logSummary(reason: reason)
        entries.removeAll(keepingCapacity: true)
        nextPresentationTime = nil
        sourceAnchorRaw = nil
        sourceAnchorUnwrapped = nil
        lastPresentedSourceOrder = nil
        lastInputAt = nil
        lastOutputAt = nil
        inputIntervals.removeAll(keepingCapacity: true)
        outputIntervals.removeAll(keepingCapacity: true)
        inputCount = 0
        outputCount = 0
        underflowCount = 0
        overflowDropCount = 0
        lateSourceDropCount = 0
        lastLogAt = CACurrentMediaTime()
        displayLink?.isPaused = true
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(Self.framesPerSecond),
            maximum: Float(Self.framesPerSecond),
            preferred: Float(Self.framesPerSecond))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard let deadline = nextPresentationTime else {
            link.isPaused = entries.isEmpty
            return
        }
        let now = link.targetTimestamp
        guard now + 0.001 >= deadline else { return }

        guard !entries.isEmpty else {
            // The display layer naturally holds the last frame. Rebuffer before resuming.
            underflowCount += 1
            nextPresentationTime = nil
            logIfNeeded(now: now)
            return
        }

        let entry = entries.removeFirst()
        entry.present()
        lastPresentedSourceOrder = entry.sourceOrder
        outputCount += 1
        if let previous = lastOutputAt, now > previous {
            outputIntervals.append(now - previous)
            if outputIntervals.count > 4_096 {
                outputIntervals.removeFirst(outputIntervals.count - 4_096)
            }
        }
        lastOutputAt = now
        // Anchor to this display tick. A delayed callback never causes catch-up burst output.
        nextPresentationTime = now + Self.cadence
        logIfNeeded(now: now)
    }

    private func sourceOrder(for timestamp: UInt32?) -> Int64 {
        guard let timestamp else {
            return (entries.last?.sourceOrder ?? lastPresentedSourceOrder ?? 0) + 1
        }
        guard let anchorRaw = sourceAnchorRaw, let anchor = sourceAnchorUnwrapped else {
            sourceAnchorRaw = timestamp
            sourceAnchorUnwrapped = Int64(timestamp)
            return Int64(timestamp)
        }
        let delta = Int64(Int32(bitPattern: timestamp &- anchorRaw))
        let unwrapped = anchor + delta
        if delta > 0 {
            sourceAnchorRaw = timestamp
            sourceAnchorUnwrapped = unwrapped
        }
        return unwrapped
    }

    private func logIfNeeded(now: CFTimeInterval) {
        guard now - lastLogAt >= 5 else { return }
        lastLogAt = now
        logSummary(reason: "periodic")
    }

    private func logSummary(reason: String) {
        let inputValues = inputIntervals.sorted()
        let outputValues = outputIntervals.sorted()
        inputIntervals.removeAll(keepingCapacity: true)
        outputIntervals.removeAll(keepingCapacity: true)
        let inputStats = intervalStats(inputValues)
        let outputStats = intervalStats(outputValues)
        let fields = [
            "reason=\(reason)",
            "pacer_input=\(inputCount)",
            "pacer_output=\(outputCount)",
            "buffer_depth=\(entries.count)",
            "buffer_underflow_count=\(underflowCount)",
            "buffer_overflow_drop_count=\(overflowDropCount)",
            "late_source_drop_count=\(lateSourceDropCount)",
            "input_interval_ms{\(inputStats)}",
            "output_interval_ms{\(outputStats)}",
        ]
        ControlLiveLog.line("pacer: \(fields.joined(separator: " "))")
    }

    private func intervalStats(_ values: [TimeInterval]) -> String {
        [
            "median=\(metric(values, 0.50))",
            "p95=\(metric(values, 0.95))",
            "p99=\(metric(values, 0.99))",
            "max=\(maximum(values))",
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
}
#endif
