// SoundTune/Audio/Engine/AudioEngine+Apps.swift
import AudioToolbox
import Foundation
import os

@MainActor
extension AudioEngine {
    // MARK: - Displayable Apps (Active + Pinned Inactive)

    /// Combined list of active apps and pinned inactive apps for UI display.
    /// Pinned apps appear first (sorted alphabetically), then unpinned active apps (sorted alphabetically).
    var displayableApps: [DisplayableApp] {
        let activeApps = apps
            .filter { !appListCoordinator.isIgnored(identifier: $0.persistenceIdentifier) }
        let activeIdentifiers = Set(activeApps.map { $0.persistenceIdentifier })

        // Get pinned apps that are not currently active
        let pinnedInactiveInfos = appListCoordinator.pinnedAppInfo()
            .filter { !activeIdentifiers.contains($0.persistenceIdentifier) }

        // Pinned active apps (sorted alphabetically)
        let pinnedActive = activeApps
            .filter { appListCoordinator.isPinned(identifier: $0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        // Pinned inactive apps (sorted alphabetically)
        let pinnedInactive = pinnedInactiveInfos
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { DisplayableApp.pinnedInactive($0) }

        // Unpinned active apps (sorted alphabetically)
        let unpinnedActive = activeApps
            .filter { !appListCoordinator.isPinned(identifier: $0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        return pinnedActive + pinnedInactive + unpinnedActive
    }

    // MARK: - Pinning

    /// Pin an active app so it remains visible when inactive.
    func pinApp(_ app: AudioApp) {
        appListCoordinator.pinApp(app)
    }

    /// Unpin an app by its persistence identifier.
    func unpinApp(_ identifier: String) {
        appListCoordinator.unpinApp(identifier)
    }

    /// Check if an app is pinned.
    func isPinned(_ app: AudioApp) -> Bool {
        appListCoordinator.isPinned(app)
    }

    /// Check if an identifier is pinned (for inactive apps).
    func isPinned(identifier: String) -> Bool {
        appListCoordinator.isPinned(identifier: identifier)
    }

    // MARK: - Ignored Apps

    /// Hide an active app so SoundTune ignores it entirely. Persists the ignore,
    /// then tears down the live tap so audio returns to natural volume.
    func ignoreApp(_ app: AudioApp) {
        appListCoordinator.recordIgnore(app)

        if let tap = taps.removeValue(forKey: app.id) {
            tap.invalidate()
        }
        appDeviceRouting.removeValue(forKey: app.id)
        followsDefault.remove(app.id)
        appliedPIDs.remove(app.id)
    }

    /// Unhide an app by its persistence identifier.
    /// Immediately creates a tap if the app is currently running.
    func unignoreApp(_ identifier: String) {
        appListCoordinator.clearIgnore(identifier)
        applyPersistedSettings()
    }

    /// Check if an identifier is hidden.
    func isIgnored(identifier: String) -> Bool {
        appListCoordinator.isIgnored(identifier: identifier)
    }

    // MARK: - Inactive App Settings (by persistence identifier)

    func getVolumeForInactive(identifier: String) -> Float {
        appListCoordinator.getVolumeForInactive(identifier: identifier)
    }

    func setVolumeForInactive(identifier: String, to volume: Float) {
        appListCoordinator.setVolumeForInactive(identifier: identifier, to: volume)
    }

    func getBoostForInactive(identifier: String) -> BoostLevel {
        appListCoordinator.getBoostForInactive(identifier: identifier)
    }

    func setBoostForInactive(identifier: String, to boost: BoostLevel) {
        appListCoordinator.setBoostForInactive(identifier: identifier, to: boost)
    }

    func getMuteForInactive(identifier: String) -> Bool {
        appListCoordinator.getMuteForInactive(identifier: identifier)
    }

    func setMuteForInactive(identifier: String, to muted: Bool) {
        appListCoordinator.setMuteForInactive(identifier: identifier, to: muted)
    }

    func getEQSettingsForInactive(identifier: String) -> EQSettings {
        appListCoordinator.getEQSettingsForInactive(identifier: identifier)
    }

    func setEQSettingsForInactive(_ settings: EQSettings, identifier: String) {
        appListCoordinator.setEQSettingsForInactive(settings, identifier: identifier)
    }

    func getDeviceRoutingForInactive(identifier: String) -> String? {
        appListCoordinator.getDeviceRoutingForInactive(identifier: identifier)
    }

    func setDeviceRoutingForInactive(identifier: String, deviceUID: String?) {
        appListCoordinator.setDeviceRoutingForInactive(identifier: identifier, deviceUID: deviceUID)
    }

    func isFollowingDefaultForInactive(identifier: String) -> Bool {
        appListCoordinator.isFollowingDefaultForInactive(identifier: identifier)
    }

    func getDeviceSelectionModeForInactive(identifier: String) -> DeviceSelectionMode {
        appListCoordinator.getDeviceSelectionModeForInactive(identifier: identifier)
    }

    func setDeviceSelectionModeForInactive(identifier: String, to mode: DeviceSelectionMode) {
        appListCoordinator.setDeviceSelectionModeForInactive(identifier: identifier, to: mode)
    }

    func getSelectedDeviceUIDsForInactive(identifier: String) -> Set<String> {
        appListCoordinator.getSelectedDeviceUIDsForInactive(identifier: identifier)
    }

    func setSelectedDeviceUIDsForInactive(identifier: String, to uids: Set<String>) {
        appListCoordinator.setSelectedDeviceUIDsForInactive(identifier: identifier, to: uids)
    }

    /// Audio levels for all active apps (for VU meter visualization)
    /// Returns a dictionary mapping PID to peak audio level (0-1)
    var audioLevels: [pid_t: Float] {
        var levels: [pid_t: Float] = [:]
        for (pid, tap) in taps {
            levels[pid] = tap.audioLevel
        }
        return levels
    }

    /// Get audio level for a specific app
    func getAudioLevel(for app: AudioApp) -> Float {
        taps[app.id]?.audioLevel ?? 0.0
    }

    // MARK: - Settings Reset

    /// Resets all persisted settings and synchronizes in-memory engine state.
    /// Active taps are kept alive but reverted to defaults (unity volume, unmuted, flat EQ).
    func handleSettingsReset() {
        // 1. Clear persisted state
        settingsManager.resetAllSettings()

        // 2. Clear in-memory routing and tracking state
        appliedPIDs.removeAll()
        appDeviceRouting.removeAll()
        followsDefault.removeAll()

        // 3. Clear cached per-app audio state
        volumeState.resetAll()

        // 4. Refresh output state caches so software-backed devices reset to defaults.
        deviceVolumeMonitor.refreshOutputDeviceStates()

        // 5. Push defaults to all active taps
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
            tap.updateEQSettings(.flat)
            tap.updateAutoEQProfile(nil)
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: false)
        }

        // 6. Re-apply from clean settings (re-establishes routing to system default)
        applyPersistedSettings()

        logger.info("Settings reset: engine state synchronized")
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let deviceUID = appDeviceRouting[app.id] {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
            if settingsManager.appSettings.loudnessCompensationEnabled {
                tap.updateLoudnessCompensation(
                    volume: effectiveLoudnessVolume(for: tap),
                    enabled: true
                )
            }
        }
    }

    func getVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    // MARK: - Boost

    func setBoost(for app: AudioApp, to boost: BoostLevel) {
        volumeState.setBoost(for: app.id, to: boost, identifier: app.persistenceIdentifier)
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    func getBoost(for app: AudioApp) -> BoostLevel {
        volumeState.getBoost(for: app.id)
    }


    func toggleMute(for app: AudioApp) {
        let current = volumeState.getMute(for: app.id)
        setMute(for: app, to: !current)
    }

    func currentVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    func isMuted(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    func isAudibleNow(bundleID: String) -> Bool {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            return false
        }
        return app.processObjectIDs.contains { $0.readProcessIsRunning() }
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        volumeState.setMute(for: app.id, to: muted, identifier: app.persistenceIdentifier)
        taps[app.id]?.isMuted = muted
    }

    func getMute(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    /// Update EQ settings for an app
    func setEQSettings(_ settings: EQSettings, for app: AudioApp) {
        guard let tap = taps[app.id] else { return }
        tap.updateEQSettings(settings)
        settingsManager.setEQSettings(settings, for: app.persistenceIdentifier)
    }

    /// Get EQ settings for an app
    func getEQSettings(for app: AudioApp) -> EQSettings {
        return settingsManager.getEQSettings(for: app.persistenceIdentifier)
    }
}
