// SoundTune/Views/Onboarding/OnboardingView.swift
import SwiftUI
import AppKit

// Intercepts the window before it is first shown (before makeKeyAndOrderFront),
// hides it, centers it, then reveals it — preventing the bottom-left flash.
private final class _WindowPositionerView: NSView {
    private var intercepted = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let window = newWindow, !intercepted else { return }
        intercepted = true
        window.alphaValue = 0
        DispatchQueue.main.async { [weak window] in
            window?.center()
            window?.alphaValue = 1
        }
    }
}

private struct WindowPositioner: NSViewRepresentable {
    func makeNSView(context: Context) -> _WindowPositionerView { _WindowPositionerView() }
    func updateNSView(_ nsView: _WindowPositionerView, context: Context) {}
}

@MainActor
struct OnboardingView: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    let permission: AudioRecordingPermission
    let bluetoothPermission: BluetoothPermission

    @Environment(\.dismiss) private var dismiss

    @State private var currentStep = 0
    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator dots
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Circle()
                        .fill(index == currentStep
                              ? DesignTokens.Colors.accentPrimary
                              : DesignTokens.Colors.textTertiary.opacity(0.4))
                        .frame(width: 6, height: 6)
                        .animation(.spring(response: 0.3), value: currentStep)
                }
            }
            .padding(.top, 28)

            // Step content
            TabView(selection: $currentStep) {
                stepFeatures.tag(0)
                stepWhyPermission.tag(1)
                stepPermissions.tag(2)
            }
            .tabViewStyle(.automatic)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: currentStep)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button(t("Cancel")) {
                        currentStep -= 1
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                } else {
                    Spacer()
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    Button(t("Next")) {
                        withAnimation {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return)
                } else {
                    Button(t("Get Started")) {
                        settings.appSettings.hasCompletedOnboarding = true
                        dismiss()
                        // Close the onboarding window via AppKit
                        NSApp.windows.first(where: { $0.identifier?.rawValue == "onboarding" })?.close()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 28)
        }
        .frame(width: 520, height: 480)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .background(WindowPositioner())
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .onAppear {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "onboarding" }) {
                window.isRestorable = false
            }
            if settings.appSettings.hasCompletedOnboarding {
                dismiss()
                NSApp.windows.first(where: { $0.identifier?.rawValue == "onboarding" })?.close()
            }
        }
    }

    // MARK: - Step 1: Features

    private var stepFeatures: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .padding(.top, 32)

            Text(t("Welcome to SoundTune"))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 16) {
                featureRow(
                    icon: "slider.horizontal.3",
                    color: DesignTokens.Colors.accentPrimary,
                    title: t("Per-App Volume Control"),
                    description: t("Set different volume levels for each app independently.")
                )
                featureRow(
                    icon: "waveform",
                    color: .purple,
                    title: t("Equalizer & Presets"),
                    description: t("Fine-tune audio with per-app and per-device EQ presets.")
                )
                featureRow(
                    icon: "keyboard",
                    color: .orange,
                    title: t("Media Key Control"),
                    description: t("Take over F10/F11/F12 to control the volume of any app.")
                )
            }
            .padding(.horizontal, 48)
            .padding(.top, 28)

            Spacer()
        }
    }

    private func featureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 2: Why the permission?

    private var stepWhyPermission: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
            }
            .padding(.top, 40)

            Text(t("Why Screen & System Audio Recording?"))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 14) {
                explanationBullet(
                    icon: "lock.shield",
                    text: t("SoundTune uses a CoreAudio feature called CATap to read the audio stream of each app — not to record it, just to route and adjust volume independently.")
                )
                explanationBullet(
                    icon: "xmark.icloud",
                    text: t("No audio data is stored or transmitted. This is how macOS exposes per-app audio to third-party apps.")
                )
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)

            Spacer()
        }
    }

    private func explanationBullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.accentPrimary)
                .frame(width: 20)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 3: Grant permissions

    private var stepPermissions: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color.green)
            }
            .padding(.top, 40)

            Text(t("Required Permissions"))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .padding(.top, 20)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: t("Screen & System Audio Recording"),
                    description: t("Needed to intercept per-app audio streams via CATap."),
                    isGranted: permission.status == .authorized,
                    action: {
                        permission.request()
                    }
                )

                permissionRow(
                    icon: "accessibility",
                    title: t("Accessibility"),
                    description: t("Needed for media key interception (F10/F11/F12)."),
                    isGranted: accessibility.isTrustedCached,
                    action: {
                        accessibility.requestAccess()
                    }
                )

                permissionRow(
                    icon: "bluetooth",
                    title: t("Bluetooth"),
                    description: t("Needed to connect and manage Bluetooth audio devices."),
                    isGranted: bluetoothPermission.status == .authorized,
                    action: {
                        bluetoothPermission.request()
                    }
                )
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)

            Text(t("You can change these in System Settings → Privacy & Security at any time."))
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .padding(.top, 16)

            Spacer()
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignTokens.Colors.glassFill)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                Label(t("Granted"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(t("Grant Access")) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(DesignTokens.Colors.glassFill.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
