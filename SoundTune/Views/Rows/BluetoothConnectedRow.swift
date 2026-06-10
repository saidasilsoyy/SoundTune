// SoundTune/Views/Rows/BluetoothConnectedRow.swift
import SwiftUI

/// A row for a paired Bluetooth device that can be connected or disconnected.
/// Handles connected state (battery display, AirPods settings) and connecting state (spinner).
struct BluetoothConnectedRow: View {
    let device: PairedBluetoothDevice
    let isConnecting: Bool
    let isDisconnecting: Bool
    let errorMessage: String?
    let batteryLevels: BluetoothBatteryStatus?
    let onToggleConnect: () -> Void
    let onOpenSettings: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(action: onToggleConnect) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ZStack {
                        Circle()
                            .fill(device.isConnected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.glassFillStrong)
                            .frame(width: 24, height: 24)

                        if let icon = device.icon {
                            Image(nsImage: icon)
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 13, height: 13)
                                .foregroundStyle(device.isConnected ? Color.white : DesignTokens.Colors.textSecondary)
                        } else {
                            Image(systemName: "headphones")
                                .font(.system(size: 11))
                                .foregroundStyle(device.isConnected ? Color.white : DesignTokens.Colors.textSecondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(DesignTokens.Typography.rowName)
                            .foregroundStyle(device.isConnected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                            .lineLimit(1)

                        statusLine
                    }

                    Spacer()

                    if isDisconnecting || isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisconnecting)

            if supportsAccessorySettings {
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(accessorySettingsLabel)
                .accessibilityLabel(accessorySettingsLabel)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isHovered ? DesignTokens.Colors.hoverSurface.opacity(0.4) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if isDisconnecting {
            Text(t("Disconnecting..."))
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        } else if isConnecting {
            Text(t("Connecting..."))
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        } else if let error = errorMessage {
            Text(error)
                .font(.system(size: 9))
                .foregroundStyle(Color.red)
        } else if device.isConnected {
            if let battery = batteryLevels {
                HStack(spacing: 8) {
                    if let left = battery.left {
                        HStack(spacing: 2) {
                            Image(systemName: "airpod.left")
                            Text(formatPercent(left))
                        }
                    }
                    if let right = battery.right {
                        HStack(spacing: 2) {
                            Image(systemName: "airpod.right")
                            Text(formatPercent(right))
                        }
                    }
                    if let caseBattery = battery.caseBattery {
                        HStack(spacing: 2) {
                            Image(systemName: "airpods.chargingcase")
                            Text(formatPercent(caseBattery))
                        }
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else {
                Text(t("Connected"))
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
    }

    private var supportsAccessorySettings: Bool {
        guard device.isConnected else { return false }
        let name = device.name.lowercased()
        return name.contains("airpods") || name.contains("beats")
    }

    private var accessorySettingsLabel: String {
        device.name.lowercased().contains("airpods") ? t("Open AirPods Settings") : t("Open Headphone Settings")
    }

    private func formatPercent(_ value: Int) -> String {
        LanguageManager.shared.formatPercentage(Double(value) / 100, maximumFractionDigits: 0)
    }
}
