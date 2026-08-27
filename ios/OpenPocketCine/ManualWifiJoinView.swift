import SwiftUI
import UIKit

struct ManualWifiJoinPrompt: Equatable, Sendable {
    let ssid: String
    let password: String
}

/// Public-API-only fallback for builds whose provisioning profile does not carry the Hotspot
/// Configuration entitlement. It intentionally does not deep-link to the private Wi-Fi pane.
struct ManualWifiJoinPanel: View {
    let prompt: ManualWifiJoinPrompt
    @State private var showsPassword = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MANUAL WI-FI JOIN")
                .font(LiveType.ui(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(StartupColors.accent)

            credential(title: "Camera Wi-Fi", value: prompt.ssid)

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(LiveType.ui(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(StartupColors.muted)
                HStack(spacing: 8) {
                    Text(showsPassword ? prompt.password : String(repeating: "•", count: 12))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(StartupColors.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(showsPassword ? "Hide" : "Show") {
                        showsPassword.toggle()
                    }
                    .buttonStyle(.borderless)
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = prompt.password
                        copied = true
                    }
                    .buttonStyle(.borderless)
                }
            }

            Text("iPhoneの設定 → Wi-Fiからこのネットワークへ接続し、接続後このアプリへ戻ってください")
                .font(LiveType.ui(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(StartupColors.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ProgressView()
                    .tint(StartupColors.accent)
                Text("アプリに戻ると接続を自動確認します")
                    .font(LiveType.ui(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(StartupColors.muted)
            }
        }
        .padding(14)
        .background(
            StartupColors.tile.opacity(0.62),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(StartupColors.accent.opacity(0.35), lineWidth: 1)
        }
    }

    private func credential(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(LiveType.ui(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(StartupColors.muted)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(StartupColors.ink)
                .textSelection(.enabled)
        }
    }
}
