// SoundTuneTests/SettingsManagerAppSettingsBindingTests.swift
import Testing
import Foundation
@testable import SoundTune

@MainActor
@Suite("SettingsManager.appSettings — direct binding setter")
struct SettingsManagerAppSettingsBindingTests {

    @Test("Direct assignment to appSettings persists the new value")
    func directAssignmentPersists() async {
        let manager = makeManager()
        var newSettings = manager.appSettings
        newSettings.defaultNewAppVolume = 0.42
        newSettings.lockInputDevice = true

        manager.appSettings = newSettings

        #expect(manager.appSettings.defaultNewAppVolume == 0.42)
        #expect(manager.appSettings.lockInputDevice == true)
    }

    @Test("Direct assignment sanitizes invalid default app volume")
    func directAssignmentSanitizesDefaultVolume() async {
        let manager = makeManager()
        var newSettings = manager.appSettings
        newSettings.defaultNewAppVolume = 4.2

        manager.appSettings = newSettings

        #expect(manager.appSettings.defaultNewAppVolume == 1.0)
    }

    @Test("Direct assignment is equivalent to updateAppSettings for the same input")
    func directAssignmentEquivalentToUpdate() async {
        let managerA = makeManager()
        let managerB = makeManager()

        var modified = managerA.appSettings
        modified.defaultNewAppVolume = 0.7
        modified.mediaKeyControlEnabled = true
        modified.showDeviceDisconnectAlerts = false

        managerA.appSettings = modified
        managerB.updateAppSettings(modified)

        #expect(managerA.appSettings == managerB.appSettings)
    }

    @Test("Per-app volume setter clamps invalid values before persisting")
    func perAppVolumeSetterClamps() {
        let manager = makeManager()

        manager.setVolume(for: "com.test.too-high", to: 9.0)
        manager.setVolume(for: "com.test.negative", to: -1.0)
        manager.setVolume(for: "com.test.nan", to: .nan)

        #expect(manager.getVolume(for: "com.test.too-high") == 1.0)
        #expect(manager.getVolume(for: "com.test.negative") == 0.0)
        #expect(manager.getVolume(for: "com.test.nan") == 1.0)
    }

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }
}
