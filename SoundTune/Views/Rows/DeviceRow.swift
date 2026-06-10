// SoundTune/Views/Rows/DeviceRow.swift
import SwiftUI

/// A row displaying an output device with volume controls and a per-device manual EQ.
struct DeviceRow: View {
    let device: AudioDevice
    let isDefault: Bool
    let volume: Float
    let isMuted: Bool
    /// The device's volume backend. Determines which slider ↔ value mapping to use.
    let volumeBackend: VolumeControlTier
    let onSetDefault: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let deviceEQSettings: EQSettings
    let userPresets: [UserEQPreset]
    let onDeviceEQChange: (EQSettings) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void
    let isFocused: Bool

    @State private var sliderValue: Double
    @State private var localEQSettings: EQSettings
    @State private var isEditing = false
    @State private var suppressSliderAutoUnmute = false
    /// Suppresses write-back when slider is being synced from a device volume change.
    /// Breaks the quantization feedback loop on USB DACs with discrete dB steps.
    @State private var isUpdatingSliderFromDevice = false
    @State private var isEQButtonHovered = false

    /// The displayed percentage value, matching EditablePercentage's formula.
    /// Used for icon and unmute logic so visual state stays consistent with the label.
    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }

    /// Show muted icon when system muted OR displayed volume is 0%.
    private var showMutedIcon: Bool { isMuted || displayedPercentage == 0 }

    /// Default slider position to restore when unmuting from 0 (50%).
    private let defaultUnmuteVolume: Double = 0.5

    private var hasActiveDeviceEQ: Bool {
        localEQSettings.isEnabled && localEQSettings.bandGains.contains { abs($0) > 0.001 }
    }

    private var eqButtonColor: Color {
        if isEQExpanded {
            return DesignTokens.Colors.interactiveActive
        } else if isEQButtonHovered || hasActiveDeviceEQ {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }

    init(
        device: AudioDevice,
        isDefault: Bool,
        volume: Float,
        isMuted: Bool,
        volumeBackend: VolumeControlTier = .hardware,
        onSetDefault: @escaping () -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        deviceEQSettings: EQSettings = .flat,
        userPresets: [UserEQPreset] = [],
        onDeviceEQChange: @escaping (EQSettings) -> Void = { _ in },
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {},
        isFocused: Bool = false
    ) {
        self.device = device
        self.isDefault = isDefault
        self.volume = volume
        self.isMuted = isMuted
        self.volumeBackend = volumeBackend
        self.onSetDefault = onSetDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.deviceEQSettings = deviceEQSettings
        self.userPresets = userPresets
        self.onDeviceEQChange = onDeviceEQChange
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        self.isFocused = isFocused
        self._sliderValue = State(initialValue: Self.volumeToSlider(volume, backend: volumeBackend))
        self._localEQSettings = State(initialValue: deviceEQSettings)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded, isFocused: isFocused) {
            deviceHeader
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isDefault {
                        onSetDefault()
                    }
                }
        } expandedContent: {
            EQPanelView(
                settings: $localEQSettings,
                userPresets: userPresets,
                onPresetSelected: { preset in
                    localEQSettings = preset.settings
                    onDeviceEQChange(preset.settings)
                },
                onUserPresetSelected: { userPreset in
                    var current = localEQSettings
                    current.bandGains = userPreset.settings.bandGains
                    localEQSettings = current
                    onDeviceEQChange(current)
                },
                onSettingsChanged: { settings in
                    onDeviceEQChange(settings)
                },
                onSavePreset: onSavePreset,
                onDeleteUserPreset: onDeleteUserPreset,
                onRenameUserPreset: onRenameUserPreset
            )
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .onChange(of: deviceEQSettings) { _, newValue in
            localEQSettings = newValue
        }
    }

    // MARK: - Device Header

    private var deviceHeader: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            DeviceBadge(icon: device.icon, isSelected: isDefault)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(DesignTokens.Typography.rowName)
                    .lineLimit(1)
                    .help(device.name)

                if hasActiveDeviceEQ {
                    Text(t("Device EQ"))
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onEQToggle()
            } label: {
                ZStack {
                    Image(systemName: "slider.vertical.3")
                        .opacity(isEQExpanded ? 0 : 1)
                        .rotationEffect(.degrees(isEQExpanded ? 90 : 0))

                    Image(systemName: "xmark")
                        .opacity(isEQExpanded ? 1 : 0)
                        .rotationEffect(.degrees(isEQExpanded ? 0 : -90))
                }
                .font(.system(size: 12))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(eqButtonColor)
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEQExpanded ? t("Close Equalizer") : t("Equalizer"))
            .help(isEQExpanded ? t("Close Equalizer") : t("Equalizer"))
            .onHover { isEQButtonHovered = $0 }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isEQExpanded)
            .animation(DesignTokens.Animation.hover, value: isEQButtonHovered)

            MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                if showMutedIcon {
                    // Unmute: restore to default if displayed as 0%.
                    if displayedPercentage == 0 {
                        suppressSliderAutoUnmute = isMuted
                        sliderValue = defaultUnmuteVolume
                    }
                    if isMuted {
                        onMuteToggle()
                    }
                } else {
                    onMuteToggle()
                }
            }

            LiquidGlassSlider(
                value: $sliderValue,
                onEditingChanged: { editing in
                    isEditing = editing
                }
            )
            .opacity(showMutedIcon ? 0.5 : 1.0)
            .onChange(of: sliderValue) { _, newValue in
                // Skip write-back when syncing from device (breaks USB DAC quantization spiral).
                if isUpdatingSliderFromDevice {
                    isUpdatingSliderFromDevice = false
                    return
                }
                onVolumeChange(Self.sliderToVolume(newValue, backend: volumeBackend))
                if suppressSliderAutoUnmute {
                    suppressSliderAutoUnmute = false
                    return
                }
                if isMuted && newValue > 0 {
                    onMuteToggle()
                }
            }
            .scrollWheelStep($sliderValue, in: 0.0...1.0)

            EditablePercentage(
                percentage: Binding(
                    get: { Int(round(sliderValue * 100)) },
                    set: { sliderValue = Double($0) / 100.0 }
                ),
                range: 0...100,
                isRowFocused: isFocused
            )
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .onChange(of: volume) { _, newValue in
            guard !isEditing else { return }
            let newSlider = Self.volumeToSlider(newValue, backend: volumeBackend)
            guard newSlider != sliderValue else { return }
            isUpdatingSliderFromDevice = true
            sliderValue = newSlider
        }
    }
}

extension DeviceRow {
    // MARK: - Volume Mapping

    static func volumeToSlider(_ volume: Float, backend: VolumeControlTier) -> Double {
        VolumeMapping.sliderFraction(forSystemGain: volume, tier: backend)
    }

    static func sliderToVolume(_ slider: Double, backend: VolumeControlTier) -> Float {
        VolumeMapping.systemGain(forSliderFraction: slider, tier: backend)
    }
}

// MARK: - Previews

#Preview("Device Row - Default") {
    PreviewContainer {
        VStack(spacing: 0) {
            DeviceRow(
                device: MockData.sampleDevices[0],
                isDefault: true,
                volume: 0.75,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[1],
                isDefault: false,
                volume: 1.0,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {},
                deviceEQSettings: EQPreset.rock.settings,
                isEQExpanded: true
            )
        }
    }
}
