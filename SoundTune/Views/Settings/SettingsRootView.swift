// SoundTune/Views/Settings/SettingsRootView.swift
import SwiftUI
import KeyboardShortcuts
import AppKit

private final class __SettingsPositionerView: NSView {
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

private struct _SettingsWindowPositioner: NSViewRepresentable {
    func makeNSView(context: Context) -> __SettingsPositionerView { __SettingsPositionerView() }
    func updateNSView(_ nsView: __SettingsPositionerView, context: Context) {}
}

@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry

    /// When `true`, omits the fixed frame and window-chrome backgrounds so the
    /// view can be embedded inside the popup instead of a standalone window.
    var isInline: Bool = false

    @State private var sortedOutputDevices: [AudioDevice] = []

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: {
                settings.appSettings.loudnessCompensationEnabled
                    && settings.appSettings.loudnessEqualizationEnabled
            },
            set: { isEnabled in
                settings.appSettings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        if isInline {
            inlineBody
        } else {
            windowBody
        }
    }

    // MARK: - Inline (popup-embedded) layout

    private var inlineBody: some View {
        ScrollView {
            sectionsContent(hPad: 0, vPad: 8)
        }
        .scrollIndicators(.never)
        .onAppear { updateSortedDevices() }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { old, new in
            if !old && new { audioEngine.handleInputLockEnabled() }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, new in
            audioEngine.setLoudnessCompensationEnabled(new)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, new in
            audioEngine.setLoudnessEqualizationEnabled(new)
        }
        .onChange(of: settings.appSettings.mediaKeyControlEnabled) { _, _ in
            mediaKeyMonitor.reconcile()
        }
    }

    // MARK: - Standalone window layout

    private var windowBody: some View {
        ScrollView {
            sectionsContent(hPad: 24, vPad: 24)
        }
        .scrollIndicators(.never)
        .frame(width: 520, height: 480)
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .background(WindowAppearanceBridge(appearance: settings.appSettings.appearance.nsAppearance))
        .background(WindowTitleBridge(title: t("SoundTune Settings")))
        .background(_SettingsWindowPositioner())
        .onAppear {
            updateSortedDevices()
            if let window = NSApp.windows.first(where: { $0.title == t("SoundTune Settings") || $0.title == "SoundTune Settings" }) {
                window.isRestorable = false
                if !MenuBarIconCoordinator.isProgrammaticSettingsOpen {
                    window.close()
                } else {
                    MenuBarIconCoordinator.isProgrammaticSettingsOpen = false
                }
            }
        }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { old, new in
            if !old && new { audioEngine.handleInputLockEnabled() }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, new in
            audioEngine.setLoudnessCompensationEnabled(new)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, new in
            audioEngine.setLoudnessEqualizationEnabled(new)
        }
        .onChange(of: settings.appSettings.mediaKeyControlEnabled) { _, _ in
            mediaKeyMonitor.reconcile()
        }
    }

    // MARK: - Shared sections content

    private func sectionsContent(hPad: CGFloat, vPad: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            generalSection
            volumeSection
            devicesSection
            mediaKeysSection
            hotkeysSection
            SystemShortcutsConflictView()
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - General Section

    private var generalSection: some View {
        SettingsSection(t("General")) {
            SettingsRow(
                t("Launch at Login"),
                description: t("Start SoundTune when you log in")
            ) {
                Toggle("", isOn: $settings.appSettings.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            SettingsRowDivider()

            SettingsRow(
                t("Language"),
                description: t("Follow macOS or choose a language")
            ) {
                Picker("", selection: $settings.appSettings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang == .system ? t("System") : lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 160, alignment: .trailing)
                .labelsHidden()
            }

            SettingsRowDivider()

            SettingsRow(
                t("Theme"),
                description: t("Match macOS, or lock to Light or Dark")
            ) {
                ThemeTilePicker(selection: $settings.appSettings.appearance)
            }
        }
    }

    // MARK: - Volume Section

    private var volumeSection: some View {
        SettingsSection(t("Volume")) {
            SettingsRow(
                t("Default Volume"),
                description: t("Initial volume for new apps")
            ) {
                VolumeSlider(
                    $settings.appSettings.defaultNewAppVolume,
                    range: 0.1...1.0,
                    width: 200
                )
            }
            SettingsRowDivider()
            SettingsRow(
                t("Loudness Compensation"),
                description: t("Boost low frequencies at low volume")
            ) {
                Toggle("", isOn: unifiedLoudnessToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                t("Volume Step"),
                description: t("How much each keypress changes the volume")
            ) {
                Picker("", selection: $settings.appSettings.volumeHotkeyStep) {
                    ForEach(VolumeHotkeyStep.allCases) { step in
                        Text(t(step.description)).tag(step)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Devices Section

    private var devicesSection: some View {
        SettingsSection(t("Devices")) {
            SettingsRow(
                t("Lock Input Device"),
                description: t("Prevent auto-switching when devices connect")
            ) {
                Toggle("", isOn: $settings.appSettings.lockInputDevice)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                t("System Sounds"),
                description: t("Where alerts and effects play")
            ) {
                SystemSoundsDevicePicker(
                    devices: sortedOutputDevices,
                    selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                    defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                    isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                    onDeviceSelected: { deviceUID in
                        if let device = sortedOutputDevices.first(where: { $0.uid == deviceUID }) {
                            deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                        }
                    },
                    onSelectFollowDefault: {
                        deviceVolumeMonitor.setSystemFollowDefault()
                    }
                )
            }
            SettingsRowDivider()
            SettingsRow(
                t("Alert Volume"),
                description: t("Volume for alerts and notifications")
            ) {
                VolumeSlider(
                    Binding(
                        get: { deviceVolumeMonitor.alertVolume },
                        set: { deviceVolumeMonitor.setAlertVolume($0) }
                    ),
                    range: 0...1,
                    width: 200
                )
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }
        }
    }

    // MARK: - Media Keys Section

    private var mediaKeysSection: some View {
        SettingsSection(t("Media Keys")) {
            SettingsRow(
                t("Media Keys Control"),
                description: t("Use F11/F12 (or volume keys) to control SoundTune")
            ) {
                Toggle("", isOn: $settings.appSettings.mediaKeyControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if !accessibility.isTrustedCached {
                SettingsRowDivider()
                AccessibilityPromptStrip(accessibility: accessibility)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if mediaKeyStatus.isOffline {
                SettingsRowDivider()
                MediaKeyOfflineCard {
                    mediaKeyMonitor.reconcile()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if settings.appSettings.mediaKeyControlEnabled && accessibility.isTrustedCached {
                SettingsRowDivider()
                SettingsRow(
                    t("HUD Style"),
                    description: t("How the volume indicator appears")
                ) {
                    HUDStyleSegmentedControl(selection: $settings.appSettings.hudStyle)
                }
            }
        }
    }

    // MARK: - Hotkeys Section

    private var hotkeysSection: some View {
        SettingsSection(t("Hotkeys")) {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(
                    t(action.displayName),
                    description: shortcutDescription(for: action)
                ) {
                    KeyboardShortcuts.Recorder(
                        for: shortcutsRegistry.name(for: action),
                        onChange: shortcutsRegistry.recordCallback(for: action)
                    )
                }
            }
        }
    }

    private func shortcutDescription(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: t("Show or hide the menu bar popup")
        case .openSettings: t("Open settings view")
        case .targetAppVolumeUp: t("Raise volume for the app playing audio")
        case .targetAppVolumeDown: t("Lower volume for the app playing audio")
        case .targetAppMuteToggle: t("Mute or unmute the app playing audio")
        }
    }

    private func updateSortedDevices() {
        sortedOutputDevices = audioEngine.prioritySortedOutputDevices
    }
}

// MARK: - System Shortcuts Conflict View

@MainActor
struct SystemShortcutsConflictView: View {
    @State private var conflicts: [SystemShortcutConflict] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !conflicts.isEmpty {
                SettingsSection(t("System Shortcuts Conflict")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.orange)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("Conflict detected with macOS System Settings"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                                
                                Text(t("macOS system shortcuts take priority over SoundTune. If a shortcut (like F11 or F12) is not working, disable or change it in System Settings."))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        
                        SettingsRowDivider()
                            .padding(.top, 4)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(conflicts) { conflict in
                                HStack(spacing: 8) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 4))
                                        .foregroundStyle(.secondary)
                                    
                                    Text(String(format: t("Currently assigned to %@ in macOS System Settings."), t(conflict.name)))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                                    
                                    Spacer()
                                    
                                    Text(conflict.keyName)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(DesignTokens.Colors.glassFillStrong)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.vertical, 8)
                        
                        SettingsRowDivider()
                        
                        HStack {
                            Spacer()
                            Button {
                                SystemShortcutsChecker.openKeyboardShortcutsSettings()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.forward.app.fill")
                                        .font(.system(size: 11))
                                    Text(t("Open Keyboard Shortcuts Settings"))
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(DesignTokens.Colors.interactiveDefault)
                                .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }
                    .background(Color.orange.opacity(0.06))
                }
            }
        }
        .onAppear {
            conflicts = SystemShortcutsChecker.checkConflicts()
        }
    }
}
