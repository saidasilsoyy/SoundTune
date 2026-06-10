// SoundTune/Audio/Engine/AudioEngine+AutoEQ.swift
import AudioToolbox
import Foundation
import os

@MainActor
extension AudioEngine {
    // MARK: - Per-Device Manual EQ

    func getDeviceEQSettings(for deviceUID: String) -> EQSettings {
        settingsManager.getDeviceEQSettings(for: deviceUID)
    }

    func setDeviceEQSettings(_ settings: EQSettings, for deviceUID: String) {
        settingsManager.setDeviceEQSettings(settings, for: deviceUID)
        applyDeviceEQToTaps(for: deviceUID)
    }

    private func applyDeviceEQToTaps(for deviceUID: String) {
        let settings = settingsManager.getDeviceEQSettings(for: deviceUID)
        for tap in taps.values {
            guard tap.currentDeviceUIDs.contains(deviceUID) else { continue }
            tap.updateDeviceEQSettings(settings)
        }
    }

    internal func applyDeviceEQToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }
        tap.updateDeviceEQSettings(settingsManager.getDeviceEQSettings(for: deviceUID))
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQProfile(for deviceUID: String) -> AutoEQProfile? {
        nil
    }

    func setAutoEQProfile(for deviceUID: String, profileID: String?) {
        settingsManager.setAutoEQSelection(for: deviceUID, to: nil)
        applyAutoEQToTaps(for: deviceUID)
    }

    func setAutoEQEnabled(for deviceUID: String, enabled: Bool) {
        settingsManager.setAutoEQSelection(for: deviceUID, to: nil)
        applyAutoEQToTaps(for: deviceUID)
    }

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        nil
    }

    var autoEQPreampEnabled: Bool {
        settingsManager.autoEQPreampEnabled
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        settingsManager.autoEQPreampEnabled = enabled
        for tap in taps.values {
            tap.setAutoEQPreampEnabled(enabled)
        }
    }

    func setLoudnessCompensationEnabled(_ enabled: Bool) {
        for tap in taps.values {
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: enabled)
        }
    }

    func setLoudnessEqualizationEnabled(_ enabled: Bool) {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = enabled
        for tap in taps.values {
            tap.updateLoudnessEqualization(settings)
        }
    }

    /// Apply AutoEQ profile to all taps currently routed to the given device.
    private func applyAutoEQToTaps(for deviceUID: String) {
        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            applyAutoEQToTap(tap)
        }
    }

    /// Synchronous in-memory AutoEQ profile lookup. nil = not yet cached.
    private func autoEQProfileForActivation(deviceUID: String) -> AutoEQProfile? {
        nil
    }

    internal func tapInitialState(forApp app: AudioApp, primaryDeviceUID: String, deviceVolume: Float) -> TapInitialState {
        var loudnessEqSettings = LoudnessEqualizerSettings()
        loudnessEqSettings.enabled = settingsManager.appSettings.loudnessEqualizationEnabled
        return TapInitialState(
            eqSettings: settingsManager.getEQSettings(for: app.persistenceIdentifier),
            deviceEQSettings: settingsManager.getDeviceEQSettings(for: primaryDeviceUID),
            autoEQProfile: autoEQProfileForActivation(deviceUID: primaryDeviceUID),
            autoEQPreampEnabled: settingsManager.autoEQPreampEnabled,
            loudnessVolume: deviceVolume * volumeState.getVolume(for: app.id),
            loudnessCompensationEnabled: settingsManager.appSettings.loudnessCompensationEnabled,
            loudnessEqualizerSettings: loudnessEqSettings
        )
    }

    /// Legacy AutoEQ support is kept inert so old settings cannot silently color
    /// the output after the UI moved to manual per-device EQ only.
    internal func applyAutoEQToTap(_ tap: any ProcessTapControlling) {
        tap.updateAutoEQProfile(nil)
    }
}
