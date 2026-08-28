#if OPENPOCKETCINE_DIAGNOSTICS
import Foundation

/// Test-only observer for Nano fragment loss. It mirrors packet metadata without participating in
/// depacketization, ACK state, ordering, deadlines, or any Production decision.
struct NanoIncompleteAUDiagnostics {
    enum DropReason: String, Sendable {
        case newGroupArrived = "new_group_arrived"
        case reset
        case timeout
        case formatChange = "format_change"
    }

    enum Correlation: String, Sendable {
        case udpSequenceGap = "udp_sequence_gap"
        case assemblerMissingWithoutSequenceGap = "assembler_missing_without_sequence_gap"
        case reorderOrLate = "reorder_or_late"
        case duplicate
        case assemblerSequenceOrGroupInterpretation = "assembler_sequence_or_group_interpretation"
        case unknown
    }

    struct Packet: Equatable, Sendable {
        var groupID: UInt16
        var frameNumber: UInt8
        var wireIndex: Int
        var datalinkSequence: UInt16
        var sourceTimestamp: UInt32?
        var arrivalTime: TimeInterval
    }

    struct Observation: Equatable, Sendable {
        var closedGroup: DropEvent?
        var newSequenceGaps: [UInt16] = []
        var duplicate = false
        var reordered = false
        var lateFragment = false
        var shouldLogFragmentEvent = false
    }

    struct DropEvent: Equatable, Sendable {
        var groupID: UInt16
        var sourceTimestamp: UInt32?
        var reason: DropReason
        var correlation: Correlation
        var expectedFragments: Int
        var receivedLocalIndices: [Int]
        var missingLocalIndices: [Int]
        var firstWireIndex: Int
        var lastWireIndex: Int
        var datalinkSequenceFirst: UInt16
        var datalinkSequenceLast: UInt16
        var udpSequenceGaps: [UInt16]
        var duplicateFragments: Int
        var outOfOrderFragments: Int
        var ageMilliseconds: Double
        var nextGroupArrived: Bool

        var logLine: String {
            let timestamp = sourceTimestamp.map(String.init) ?? "unknown"
            return "nano-incomplete-au: group_id=\(groupID) source_timestamp=\(timestamp) reason=\(reason.rawValue) correlation=\(correlation.rawValue) expected_fragments=\(expectedFragments) expected_basis=observed_wire_span received_fragments=\(receivedLocalIndices.count) received_local_indices=\(Self.list(receivedLocalIndices)) missing_local_indices=\(Self.list(missingLocalIndices)) first_wire_index=\(firstWireIndex) last_wire_index=\(lastWireIndex) datalink_seq_first=\(datalinkSequenceFirst) datalink_seq_last=\(datalinkSequenceLast) udp_seq_gaps=\(Self.list(udpSequenceGaps.map(Int.init))) duplicate_fragments=\(duplicateFragments) out_of_order_fragments=\(outOfOrderFragments) age_ms=\(String(format: "%.1f", ageMilliseconds)) next_group_arrived=\(nextGroupArrived)"
        }

        private static func list(_ values: [Int]) -> String {
            "[\(values.map(String.init).joined(separator: ","))]"
        }
    }

    private struct Group {
        var groupID: UInt16
        var frameNumber: UInt8
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var sourceTimestamp: UInt32?
        var positions: Set<Int> = []
        var missingPositionCandidates: Set<Int> = []
        var firstWireIndex: Int
        var lastWireIndex: Int
        var firstSequence: UInt16
        var lastSequence: UInt16
        var latestSequenceBlock: UInt16
        var missingSequenceBlocks: Set<UInt16> = []
        var duplicateCount = 0
        var reorderCount = 0
        var lateCount = 0
    }

    private struct ClosedGroup {
        var groupID: UInt16
        var frameNumber: UInt8
        var closedAt: TimeInterval
    }

    private var current: Group?
    private var recentlyClosed: [ClosedGroup] = []
    private var lastFragmentEventLogAt: TimeInterval = 0

    mutating func observe(_ packet: Packet) -> Observation {
        var observation = Observation()
        if let active = current, active.frameNumber != packet.frameNumber {
            observation.closedGroup = makeDropEvent(
                active, reason: .newGroupArrived, now: packet.arrivalTime)
            rememberClosed(active, at: packet.arrivalTime)
            current = nil
        }

        observation.lateFragment = recentlyClosed.contains {
            $0.groupID == packet.groupID && $0.frameNumber == packet.frameNumber
                && packet.arrivalTime - $0.closedAt <= 1.0
        }
        var countedLate = false

        if current == nil {
            current = Group(
                groupID: packet.groupID, frameNumber: packet.frameNumber,
                firstSeen: packet.arrivalTime, lastSeen: packet.arrivalTime,
                sourceTimestamp: packet.sourceTimestamp,
                firstWireIndex: packet.wireIndex, lastWireIndex: packet.wireIndex,
                firstSequence: packet.datalinkSequence,
                lastSequence: packet.datalinkSequence,
                latestSequenceBlock: Self.sequenceBlock(packet.datalinkSequence))
        }

        guard var group = current else { return observation }
        group.lastSeen = packet.arrivalTime
        group.lastSequence = packet.datalinkSequence
        if group.sourceTimestamp == nil {
            group.sourceTimestamp = packet.sourceTimestamp
        }

        if group.positions.contains(packet.wireIndex) {
            observation.duplicate = group.duplicateCount == 0
            group.duplicateCount += 1
        } else {
            if packet.wireIndex < group.lastWireIndex {
                observation.reordered = group.reorderCount == 0
                group.reorderCount += 1
            } else if packet.wireIndex > group.lastWireIndex + 1 {
                for missing in (group.lastWireIndex + 1)..<packet.wireIndex {
                    group.missingPositionCandidates.insert(missing)
                }
            }
            if group.missingPositionCandidates.remove(packet.wireIndex) != nil {
                observation.lateFragment = group.lateCount == 0
                group.lateCount += 1
                countedLate = true
            }
            group.positions.insert(packet.wireIndex)
            group.firstWireIndex = min(group.firstWireIndex, packet.wireIndex)
            group.lastWireIndex = max(group.lastWireIndex, packet.wireIndex)
        }

        let block = Self.sequenceBlock(packet.datalinkSequence)
        let delta = block &- group.latestSequenceBlock
        if delta > 8, delta < 0x8000 {
            var missing = group.latestSequenceBlock &+ 8
            while missing != block {
                if group.missingSequenceBlocks.insert(missing).inserted {
                    observation.newSequenceGaps.append(missing)
                }
                missing &+= 8
            }
            group.latestSequenceBlock = block
        } else if delta == 8 {
            group.latestSequenceBlock = block
        }
        group.missingSequenceBlocks.remove(block)
        if observation.lateFragment, !countedLate { group.lateCount += 1 }
        if observation.duplicate || observation.reordered || observation.lateFragment,
            packet.arrivalTime - lastFragmentEventLogAt >= 0.250
        {
            observation.shouldLogFragmentEvent = true
            lastFragmentEventLogAt = packet.arrivalTime
        }
        current = group
        return observation
    }

    mutating func discardCurrent(reason: DropReason, at now: TimeInterval) -> DropEvent? {
        guard let group = current else { return nil }
        let event = makeDropEvent(group, reason: reason, now: now)
        rememberClosed(group, at: now)
        current = nil
        return event
    }

    private mutating func rememberClosed(_ group: Group, at now: TimeInterval) {
        recentlyClosed.append(
            ClosedGroup(groupID: group.groupID, frameNumber: group.frameNumber, closedAt: now))
        recentlyClosed.removeAll { now - $0.closedAt > 1.0 }
        if recentlyClosed.count > 8 {
            recentlyClosed.removeFirst(recentlyClosed.count - 8)
        }
    }

    private func makeDropEvent(
        _ group: Group, reason: DropReason, now: TimeInterval
    ) -> DropEvent {
        let positions = group.positions.sorted()
        let expected = max(0, group.lastWireIndex - group.firstWireIndex + 1)
        let received = positions.map { $0 - group.firstWireIndex }
        let missing = (0..<expected).filter { !group.positions.contains(group.firstWireIndex + $0) }
        let sequenceGaps = group.missingSequenceBlocks.sorted()
        let correlation: Correlation
        if !sequenceGaps.isEmpty, !missing.isEmpty {
            correlation = .udpSequenceGap
        } else if !missing.isEmpty {
            correlation = .assemblerMissingWithoutSequenceGap
        } else if group.reorderCount > 0 || group.lateCount > 0 {
            correlation = .reorderOrLate
        } else if group.duplicateCount > 0 {
            correlation = .duplicate
        } else if reason == .newGroupArrived {
            correlation = .assemblerSequenceOrGroupInterpretation
        } else {
            correlation = .unknown
        }
        return DropEvent(
            groupID: group.groupID, sourceTimestamp: group.sourceTimestamp, reason: reason,
            correlation: correlation, expectedFragments: expected,
            receivedLocalIndices: received, missingLocalIndices: missing,
            firstWireIndex: group.firstWireIndex, lastWireIndex: group.lastWireIndex,
            datalinkSequenceFirst: group.firstSequence,
            datalinkSequenceLast: group.lastSequence, udpSequenceGaps: sequenceGaps,
            duplicateFragments: group.duplicateCount,
            outOfOrderFragments: group.reorderCount + group.lateCount,
            ageMilliseconds: max(0, now - group.firstSeen) * 1_000,
            nextGroupArrived: reason == .newGroupArrived)
    }

    private static func sequenceBlock(_ sequence: UInt16) -> UInt16 {
        sequence & 0xFFF8
    }

}
#endif
