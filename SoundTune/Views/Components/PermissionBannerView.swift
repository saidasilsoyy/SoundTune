// SoundTune/Views/Components/PermissionBannerView.swift
import SwiftUI

struct PermissionBannerView: View {
    let permission: AudioRecordingPermission

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "speaker.slash")
                    .font(.title)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)

                Text(t("Audio capture access required"))
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                if permission.status == .denied {
                    Text(t("Enable in System Settings ➔ Privacy & Security ➔ Screen & System Audio Recording"))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                }

                actionButton
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    @ViewBuilder
    private var actionButton: some View {
        if permission.status == .denied {
            Button(t("Open System Settings")) {
                permission.request()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button(t("Grant Access")) {
                permission.request()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

}
