// SoundTune/Views/Components/BluetoothPermissionPrompt.swift
import SwiftUI

/// Inline prompt shown in the popup when Bluetooth permission is not yet granted.
struct BluetoothPermissionPrompt: View {
    let bluetoothPermission: BluetoothPermission

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(t("Bluetooth access required"))
                    .font(DesignTokens.Typography.rowNameBold)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(t("Needed to discover and connect paired Bluetooth audio devices."))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()

            if bluetoothPermission.status == .denied {
                Button(t("Settings")) {
                    bluetoothPermission.request()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(t("Grant Access")) {
                    bluetoothPermission.request()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.glassFill)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius))
    }
}
