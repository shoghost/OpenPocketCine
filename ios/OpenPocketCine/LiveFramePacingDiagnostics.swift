import Foundation
import OpenPocketViewCore
import os

/// Correlation token carried with one completed camera access unit. Timing is monotonic so wall-clock
/// changes cannot create false stalls.
struct LiveFrameTrace: Sendable {
    let id: UInt64
    let udpArrival: TimeInterval
    let accessUnitComplete: TimeInterval
    let sourceTimestamp: UInt32?
}

struct LivePacedAccessUnit: Sendable {
    let bytes: [UInt8]
    let trace: LiveFrameTrace
}

#if OPENPOCKETCINE_DIAGNOSTICS
enum FramePacingStage: String, CaseIterable, Sendable {
    case udpFrameArrival = "udp_frame_arrival"
    case accessUnitComplete = "access_unit_complete"
    case accessUnitBufferInput = "au_buffer_input"
    case accessUnitBufferOutput = "au_buffer_output"
    case decoderInput = "decoder_input"
    case decoderOutput = "decoder_output"
    case displaySubmit = "display_submit"
}

struct FramePacingIntervalSummary: Equatable, Sendable {
    var count: Int
    var medianMs: Double
    var p95Ms: Double
    var p99Ms: Double
    var maxMs: Double

    init(intervalsSeconds: [Double]) {
        let values = intervalsSeconds.filter { $0 > 0 }.map { $0 * 1_000 }.sorted()
        count = values.count
        medianMs = Self.percentile(values, 0.50)
        p95Ms = Self.percentile(values, 0.95)
        p99Ms = Self.percentile(values, 0.99)
        maxMs = values.last ?? 0
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int(ceil(fraction * Double(sorted.count))) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }
}

enum FramePacingGapCause: String, Sendable {
    case udp = "A_udp_source_gap"
    case accessUnit = "B_access_unit_completion"
    case decoder = "C_decoder_output"
    case display = "D_display_or_main_thread"
    case timestamp = "E_timestamp_or_pacing"
    case incomplete = "dropped_incomplete_avc"
    case idrWait = "dropped_while_waiting_for_idr"
    case unknown = "unclassified"
}

enum FramePacingClassifier {
    static func classify(
        udpMs: Double?, accessUnitMs: Double?, decoderInputMs: Double?, decoderOutputMs: Double?,
        displayMs: Double?, sourceTimestampMs: Double?, thresholdMs: Double = 50
    ) -> FramePacingGapCause {
        if let udpMs, udpMs > thresholdMs { return .udp }
        if let sourceTimestampMs, sourceTimestampMs > thresholdMs,
            (udpMs ?? 0) <= thresholdMs
        {
            return .timestamp
        }
        if let accessUnitMs, accessUnitMs > thresholdMs { return .accessUnit }
        if let decoderInputMs, decoderInputMs > thresholdMs { return .display }
        if let decoderOutputMs, decoderOutputMs > thresholdMs { return .decoder }
        if let displayMs, displayMs > thresholdMs,
            (decoderInputMs ?? 0) <= thresholdMs
        {
            return .display
        }
        return .unknown
    }
}

/// Low-overhead, diagnostics-only probe for occasional live-view pacing gaps. Hot paths only take a
/// short lock and append value types; CSV I/O and human-readable logging run on a utility queue.
final class LiveFramePacingDiagnostics: @unchecked Sendable {
    static let shared = LiveFramePacingDiagnostics()
    static let isEnabled = true

    private struct FrameTimes {
        var sourceTimestamp: UInt32?
        var sourceDeltaMs: Double? = nil
        var times: [FramePacingStage: TimeInterval] = [:]
        var intervals: [FramePacingStage: TimeInterval] = [:]
    }

    private struct State {
        var frames: [UInt64: FrameTimes] = [:]
        var lastStageTime: [FramePacingStage: TimeInterval] = [:]
        var intervals: [FramePacingStage: [TimeInterval]] = [:]
        var lastSourceTimestamp: UInt32?
        var sourceIntervals: [TimeInterval] = []
        var gapCounts: [FramePacingStage: [Int: Int]] = [:]
        var lastSummaryAt: TimeInterval = 0
        var incompleteFrames = 0
        var duplicateFragments = 0
        var reorderedFragments = 0
        var idrWaitDrops = 0
        var vtCallbackCount = 0
        var lastVTCallbackAt: TimeInterval?
        var vtCallbackIntervals: [TimeInterval] = []
        var vtStatusHistogram: [Int32: Int] = [:]
        var vtInfoFlagsHistogram: [UInt32: Int] = [:]
        var vtFrameDroppedCount = 0
        var vtNilImageBufferCount = 0
        var vtSuccessfulImageBufferCount = 0
        var csvRows: [String] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let writer = DispatchQueue(label: "opv.frame-pacing.csv", qos: .utility)
    private let log = Logger(
        subsystem: "com.opencapture.openpocketcine", category: "frame-pacing")
    private let historyLimit = 4_096
    private let flushRows = 128
    private let thresholds = [50, 66, 100, 150]
    private let fileName = "live-frame-pacing.csv"

    private init() {}

    static func djiRecordTimestamp(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.count >= 16, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1,
            bytes[3] == 0xff
        else { return nil }
        return UInt32(bytes[12]) | (UInt32(bytes[13]) << 8) | (UInt32(bytes[14]) << 16)
            | (UInt32(bytes[15]) << 24)
    }

    func reset() {
        lock.withLock { state in
            state = State()
        }
        writer.async { [fileName] in
            guard let directory = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first else { return }
            let url = directory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
        }
    }

    func noteUDPFrame(id: UInt64, at: TimeInterval) {
        let trace = LiveFrameTrace(
            id: id, udpArrival: at, accessUnitComplete: at, sourceTimestamp: nil)
        note(.udpFrameArrival, trace: trace, at: at)
    }

    func noteAccessUnitComplete(_ trace: LiveFrameTrace) {
        note(.accessUnitComplete, trace: trace, at: trace.accessUnitComplete)
    }

    func noteAccessUnitBufferInput(_ trace: LiveFrameTrace, at time: TimeInterval) {
        note(.accessUnitBufferInput, trace: trace, at: time)
    }

    func noteAccessUnitBufferOutput(_ trace: LiveFrameTrace, at time: TimeInterval) {
        note(.accessUnitBufferOutput, trace: trace, at: time)
    }

    func noteDecoderInput(_ trace: LiveFrameTrace) {
        note(.decoderInput, trace: trace, at: ProcessInfo.processInfo.systemUptime)
    }

    func noteDecoderOutput(
        _ trace: LiveFrameTrace,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        note(.decoderOutput, trace: trace, at: time)
    }

    /// Called at the very start of every VideoToolbox output callback, before status/self/image
    /// guards, so callback cadence and decoder outcomes are not biased toward successful images.
    func noteVideoToolboxCallback(
        status: Int32,
        infoFlags: UInt32,
        frameDropped: Bool,
        hasImageBuffer: Bool,
        at time: TimeInterval
    ) {
        lock.withLock { state in
            state.vtCallbackCount += 1
            if let previous = state.lastVTCallbackAt, time > previous {
                state.vtCallbackIntervals.append(time - previous)
                if state.vtCallbackIntervals.count > historyLimit {
                    state.vtCallbackIntervals.removeFirst(
                        state.vtCallbackIntervals.count - historyLimit)
                }
            }
            state.lastVTCallbackAt = time
            state.vtStatusHistogram[status, default: 0] += 1
            state.vtInfoFlagsHistogram[infoFlags, default: 0] += 1
            if frameDropped { state.vtFrameDroppedCount += 1 }
            if hasImageBuffer {
                if status == 0 { state.vtSuccessfulImageBufferCount += 1 }
            } else {
                state.vtNilImageBufferCount += 1
            }
        }
    }

    func noteDisplaySubmit(_ trace: LiveFrameTrace) {
        note(.displaySubmit, trace: trace, at: ProcessInfo.processInfo.systemUptime)
    }

    func noteIncompleteFrame(id: UInt64) {
        lock.withLock { state in
            state.incompleteFrames += 1
            if let frame = state.frames.removeValue(forKey: id) {
                state.csvRows.append(Self.csvRow(id, frame, .incomplete))
            }
        }
    }
    func noteDuplicateFragment() { lock.withLock { $0.duplicateFragments += 1 } }
    func noteReorderedFragment() { lock.withLock { $0.reorderedFragments += 1 } }
    func noteIDRWaitDrop(_ trace: LiveFrameTrace) {
        lock.withLock { state in
            state.idrWaitDrops += 1
            if let frame = state.frames.removeValue(forKey: trace.id) {
                state.csvRows.append(Self.csvRow(trace.id, frame, .idrWait))
            }
        }
    }

    /// Breaks interval correlation across suspension without deleting the session CSV.
    /// The rows completed before the boundary are queued for disk; stale partial traces are dropped.
    func noteLifecycleBoundary() {
        let rows = lock.withLock { state -> [String] in
            let pending = state.csvRows
            state.csvRows.removeAll(keepingCapacity: true)
            state.frames.removeAll(keepingCapacity: true)
            state.lastStageTime.removeAll(keepingCapacity: true)
            state.lastSourceTimestamp = nil
            state.lastVTCallbackAt = nil
            return pending
        }
        flush(rows)
    }

    /// Drains rows accumulated at the time of the call and completes after all earlier CSV writes.
    /// Frame collection remains live; rows arriving later stay in the next batch.
    func flushPending(completion: @escaping () -> Void) {
        let rows = lock.withLock { state -> [String] in
            let pending = state.csvRows
            state.csvRows.removeAll(keepingCapacity: true)
            return pending
        }
        writer.async { [fileName] in
            if !rows.isEmpty {
                Self.write(rows, fileName: fileName)
            }
            completion()
        }
    }

    private func note(_ stage: FramePacingStage, trace: LiveFrameTrace, at now: TimeInterval) {
        var rows: [String] = []
        var summary: String?
        lock.withLock { state in
            var frame = state.frames[trace.id] ?? FrameTimes(sourceTimestamp: trace.sourceTimestamp)
            frame.sourceTimestamp = trace.sourceTimestamp
            frame.times[stage] = now
            if let previous = state.lastStageTime[stage], now > previous {
                let interval = now - previous
                frame.intervals[stage] = interval
                var stageIntervals = state.intervals[stage] ?? []
                stageIntervals.append(interval)
                if stageIntervals.count > historyLimit {
                    stageIntervals.removeFirst(stageIntervals.count - historyLimit)
                }
                state.intervals[stage] = stageIntervals
                for threshold in thresholds where interval * 1_000 > Double(threshold) {
                    var counts = state.gapCounts[stage] ?? [:]
                    counts[threshold, default: 0] += 1
                    state.gapCounts[stage] = counts
                }
            }
            state.lastStageTime[stage] = now

            if stage == .accessUnitComplete, let timestamp = trace.sourceTimestamp {
                if let previous = state.lastSourceTimestamp {
                    let delta = timestamp &- previous
                    // Nano's observed record clock is milliseconds. Resets/wraps are retained in
                    // CSV as raw timestamps but excluded from pacing classification.
                    if delta > 0, delta < 1_000 {
                        frame.sourceDeltaMs = Double(delta)
                        state.sourceIntervals.append(Double(delta) / 1_000)
                        if state.sourceIntervals.count > historyLimit {
                            state.sourceIntervals.removeFirst(
                                state.sourceIntervals.count - historyLimit)
                        }
                    }
                }
                state.lastSourceTimestamp = timestamp
            }
            state.frames[trace.id] = frame

            if stage == .displaySubmit {
                let cause = FramePacingClassifier.classify(
                    udpMs: frame.intervals[.udpFrameArrival].map { $0 * 1_000 },
                    accessUnitMs: frame.intervals[.accessUnitComplete].map { $0 * 1_000 },
                    decoderInputMs: frame.intervals[.decoderInput].map { $0 * 1_000 },
                    decoderOutputMs: frame.intervals[.decoderOutput].map { $0 * 1_000 },
                    displayMs: frame.intervals[.displaySubmit].map { $0 * 1_000 },
                    sourceTimestampMs: frame.sourceDeltaMs)
                state.csvRows.append(Self.csvRow(trace.id, frame, cause))
                state.frames[trace.id] = nil
            }
            // Bound traces that were dropped before display.
            if state.frames.count > 512 {
                for key in state.frames.keys.sorted().prefix(state.frames.count - 512) {
                    state.frames[key] = nil
                }
            }
            if state.csvRows.count >= flushRows {
                rows = state.csvRows
                state.csvRows.removeAll(keepingCapacity: true)
            }
            if now - state.lastSummaryAt >= 5 {
                state.lastSummaryAt = now
                summary = Self.summaryLine(state)
                if !state.csvRows.isEmpty {
                    rows.append(contentsOf: state.csvRows)
                    state.csvRows.removeAll(keepingCapacity: true)
                }
            }
        }
        flush(rows)
        if let summary {
            log.info("\(summary, privacy: .public)")
            ControlLiveLog.line(summary)
        }
    }

    private static func csvRow(
        _ id: UInt64, _ frame: FrameTimes, _ cause: FramePacingGapCause
    ) -> String {
        func value(_ stage: FramePacingStage) -> String {
            frame.times[stage].map { String(format: "%.6f", $0) } ?? ""
        }
        func interval(_ stage: FramePacingStage) -> String {
            frame.intervals[stage].map { String(format: "%.3f", $0 * 1_000) } ?? ""
        }
        return [
            String(id), frame.sourceTimestamp.map { String($0) } ?? "",
            value(.udpFrameArrival), value(.accessUnitComplete), value(.accessUnitBufferInput),
            value(.accessUnitBufferOutput), value(.decoderInput), value(.decoderOutput),
            value(.displaySubmit), interval(.udpFrameArrival), interval(.accessUnitComplete),
            interval(.accessUnitBufferInput), interval(.accessUnitBufferOutput),
            interval(.decoderInput), interval(.decoderOutput), interval(.displaySubmit),
            frame.sourceDeltaMs.map { String(format: "%.3f", $0) } ?? "",
            cause.rawValue,
        ].joined(separator: ",")
    }

    private static func summaryLine(_ state: State) -> String {
        let stages = FramePacingStage.allCases.map { stage -> String in
            let stats = FramePacingIntervalSummary(intervalsSeconds: state.intervals[stage] ?? [])
            let gaps = [50, 66, 100, 150].map {
                "gt\($0)=\(state.gapCounts[stage]?[$0] ?? 0)"
            }.joined(separator: "/")
            let name: String
            switch stage {
            case .udpFrameArrival: name = "udp_frame_interval_ms"
            case .accessUnitComplete: name = "au_complete_interval_ms"
            case .accessUnitBufferInput: name = "au_buffer_input_interval_ms"
            case .accessUnitBufferOutput: name = "au_buffer_output_interval_ms"
            case .decoderInput: name = "decoder_input_interval_ms"
            case .decoderOutput: name = "decoder_output_interval_ms"
            case .displaySubmit: name = "display_submit_interval_ms"
            }
            return "\(name){n=\(stats.count) med=\(f(stats.medianMs)) p95=\(f(stats.p95Ms)) p99=\(f(stats.p99Ms)) max=\(f(stats.maxMs)) \(gaps)}"
        }.joined(separator: " ")
        let source = FramePacingIntervalSummary(intervalsSeconds: state.sourceIntervals)
        let vt = FramePacingIntervalSummary(intervalsSeconds: state.vtCallbackIntervals)
        let statuses = state.vtStatusHistogram.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }.joined(separator: "/")
        let flags = state.vtInfoFlagsHistogram.sorted { $0.key < $1.key }
            .map { String(format: "0x%X:%d", $0.key, $0.value) }.joined(separator: "/")
        return "pacing: \(stages) source_timestamp_interval_ms{n=\(source.count) med=\(f(source.medianMs)) p95=\(f(source.p95Ms)) p99=\(f(source.p99Ms)) max=\(f(source.maxMs))} vt_callback_interval_ms{n=\(vt.count) med=\(f(vt.medianMs)) p95=\(f(vt.p95Ms)) p99=\(f(vt.p99Ms)) max=\(f(vt.maxMs))} vt_callbacks=\(state.vtCallbackCount) vt_status{\(statuses)} vt_info_flags{\(flags)} vt_frame_dropped=\(state.vtFrameDroppedCount) vt_nil_image=\(state.vtNilImageBufferCount) vt_success_image=\(state.vtSuccessfulImageBufferCount) incomplete=\(state.incompleteFrames) dup=\(state.duplicateFragments) reorder=\(state.reorderedFragments) idrWait=\(state.idrWaitDrops)"
    }

    private static func f(_ value: Double) -> String { String(format: "%.1f", value) }

    private func flush(_ rows: [String]) {
        guard !rows.isEmpty else { return }
        writer.async { [fileName] in
            Self.write(rows, fileName: fileName)
        }
    }

    private static func write(_ rows: [String], fileName: String) {
        guard let directory = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }
        let url = directory.appendingPathComponent(fileName)
        let header = "frame_id,source_timestamp,udp_arrival_s,au_complete_s,au_buffer_input_s,au_buffer_output_s,decoder_input_s,decoder_output_s,display_submit_s,udp_interval_ms,au_interval_ms,au_buffer_input_interval_ms,au_buffer_output_interval_ms,decoder_input_interval_ms,decoder_output_interval_ms,display_interval_ms,source_interval_ms,cause\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data(header.utf8).write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((rows.joined(separator: "\n") + "\n").utf8))
    }
}
#else
/// Production target shim. No diagnostic state, locks, tasks, logs, or files are created.
final class LiveFramePacingDiagnostics: @unchecked Sendable {
    static let shared = LiveFramePacingDiagnostics()
    static let isEnabled = false
    private init() {}
}
#endif
