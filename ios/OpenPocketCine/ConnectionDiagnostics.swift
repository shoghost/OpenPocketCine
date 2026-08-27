import Foundation
import NetworkExtension
import OpenPocketViewCore
import SwiftUI

enum ConnectionDiagnosticStage: String, CaseIterable, Equatable, Identifiable, Sendable {
    case bleConnect
    case pairing
    case approval
    case wifiSSID
    case wifiPassword
    case hotspotApply
    case wifiVerification
    case datalink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bleConnect: "1. BLE connect"
        case .pairing: "2. Pairing"
        case .approval: "3. Approval"
        case .wifiSSID: "4. SSID"
        case .wifiPassword: "5. Password"
        case .hotspotApply: "6. Hotspot apply"
        case .wifiVerification: "7. Wi-Fi verification"
        case .datalink: "8. Datalink"
        }
    }
}

enum ConnectionDiagnosticState: String, Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

protocol ConnectionDiagnosticError: Error {
    var diagnosticDomain: String { get }
    var diagnosticCode: Int { get }
    var diagnosticDescription: String { get }
}

struct ConnectionDiagnosticErrorInfo: Equatable, Sendable {
    let domain: String
    let code: Int
    let description: String

    init(error: Error) {
        if let diagnostic = error as? ConnectionDiagnosticError {
            domain = diagnostic.diagnosticDomain
            code = diagnostic.diagnosticCode
            description = diagnostic.diagnosticDescription
            return
        }
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        description = nsError.localizedDescription
    }

    var isHotspotInternalError: Bool {
        domain == NEHotspotConfigurationErrorDomain
            && code == NEHotspotConfigurationError.internal.rawValue
    }
}

struct ConnectionDiagnosticEntry: Identifiable, Equatable, Sendable {
    let stage: ConnectionDiagnosticStage
    var state: ConnectionDiagnosticState
    var phase: String
    var detail: String
    var error: ConnectionDiagnosticErrorInfo?

    var id: ConnectionDiagnosticStage { stage }

    static func pending(_ stage: ConnectionDiagnosticStage) -> Self {
        Self(stage: stage, state: .pending, phase: "Not started", detail: "", error: nil)
    }

    var failureSummary: String {
        guard let error else { return detail }
        return "\(stage.title): \(error.domain) code=\(error.code) — \(error.description)"
    }
}

extension CameraSession {
    func resetConnectionDiagnostics() {
        connectionDiagnostics = ConnectionDiagnosticStage.allCases.map(
            ConnectionDiagnosticEntry.pending)
        activeConnectionDiagnosticStage = nil
    }

    func beginConnectionDiagnostic(_ stage: ConnectionDiagnosticStage, detail: String = "") {
        activeConnectionDiagnosticStage = stage
        updateConnectionDiagnostic(stage, state: .running, detail: detail, error: nil)
    }

    func succeedConnectionDiagnostic(_ stage: ConnectionDiagnosticStage, detail: String = "") {
        updateConnectionDiagnostic(stage, state: .succeeded, detail: detail, error: nil)
    }

    @discardableResult
    func failCurrentConnectionDiagnostic(_ error: Error) -> ConnectionDiagnosticEntry {
        let stage = activeConnectionDiagnosticStage ?? .bleConnect
        let info = ConnectionDiagnosticErrorInfo(error: error)
        updateConnectionDiagnostic(
            stage, state: .failed, detail: info.description, error: info)
        return connectionDiagnostics.first { $0.stage == stage }
            ?? ConnectionDiagnosticEntry(
                stage: stage, state: .failed, phase: phase.label,
                detail: info.description, error: info)
    }

    private func updateConnectionDiagnostic(
        _ stage: ConnectionDiagnosticStage,
        state: ConnectionDiagnosticState,
        detail: String,
        error: ConnectionDiagnosticErrorInfo?
    ) {
        if connectionDiagnostics.isEmpty { resetConnectionDiagnostics() }
        let entry = ConnectionDiagnosticEntry(
            stage: stage, state: state, phase: phase.label, detail: detail, error: error)
        if let index = connectionDiagnostics.firstIndex(where: { $0.stage == stage }) {
            connectionDiagnostics[index] = entry
        } else {
            connectionDiagnostics.append(entry)
        }
        let domain = error?.domain ?? "—"
        let code = error.map { String($0.code) } ?? "—"
        let description = error?.description ?? detail
        ControlLiveLog.line(
            "connect-diagnostic: stage=\(stage.rawValue) state=\(state.rawValue) phase=\(phase.label) domain=\(domain) code=\(code) description=\(description)"
        )
    }
}

struct ConnectionDiagnosticPanel: View {
    let entries: [ConnectionDiagnosticEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONNECTION DIAGNOSTICS")
                .font(LiveType.ui(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(StartupColors.muted)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(tint(entry.state))
                            .frame(width: 7, height: 7)
                        Text(entry.stage.title)
                            .font(LiveType.ui(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(StartupColors.ink)
                        Spacer(minLength: 4)
                        Text(entry.state.rawValue.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(tint(entry.state))
                    }
                    if entry.state != .pending {
                        Text("phase: \(entry.phase)")
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(StartupColors.muted)
                    }
                    if let error = entry.error {
                        Text("domain: \(error.domain)  code: \(error.code)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(StartupColors.ink)
                        Text(error.description)
                            .font(LiveType.ui(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(StartupColors.muted)
                        if error.isHotspotInternalError {
                            Text(
                                "Hotspot Configuration returned internal. A missing entitlement after free signing is one possible cause; confirm the signed profile before enabling Manual Wi-Fi fallback."
                            )
                            .font(LiveType.ui(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(StartupColors.accent)
                        }
                    } else if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(LiveType.ui(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(StartupColors.muted)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(12)
        .background(
            StartupColors.tile.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(StartupColors.border.opacity(0.14), lineWidth: 1)
        }
    }

    private func tint(_ state: ConnectionDiagnosticState) -> Color {
        switch state {
        case .pending: StartupColors.muted
        case .running: StartupColors.accent
        case .succeeded: StartupColors.ready
        case .failed: .red
        }
    }
}
