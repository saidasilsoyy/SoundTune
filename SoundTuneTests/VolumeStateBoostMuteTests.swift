// SoundTuneTests/VolumeStateBoostMuteTests.swift
import Testing
import Foundation
@testable import SoundTune

// MARK: - Boost

@Suite("VolumeState — Boost")
@MainActor
struct VolumeStateBoostTests {

    @Test("Default boost is x1 for unknown pid")
    func defaultBoost() {
        let state = VolumeState()
        #expect(state.getBoost(for: 99) == .x1)
    }

    @Test("setBoost persists via settingsManager")
    func setBoostPersists() {
        let manager = makeManager()
        let state = VolumeState(settingsManager: manager)
        state.setBoost(for: 1, to: .x2, identifier: "com.test.app")
        #expect(state.getBoost(for: 1) == .x2)
        #expect(manager.getBoost(for: "com.test.app") == .x2)
    }

    @Test("setBoost without existing state creates new state")
    func setBoostCreatesState() {
        let manager = makeManager()
        let state = VolumeState(settingsManager: manager)
        state.setBoost(for: 5, to: .x4, identifier: "com.test.new")
        #expect(state.getBoost(for: 5) == .x4)
    }

    @Test("setBoost on existing state updates without touching volume")
    func setBoostPreservesVolume() {
        let state = VolumeState()
        state.setVolume(for: 10, to: 0.7, identifier: "com.test.vol")
        state.setBoost(for: 10, to: .x3)
        #expect(state.getVolume(for: 10) == 0.7)
        #expect(state.getBoost(for: 10) == .x3)
    }

    @Test("loadSavedBoost reads from settingsManager")
    func loadSavedBoost() {
        let manager = makeManager()
        manager.setBoost(for: "com.test.saved", to: .x4)
        let state = VolumeState(settingsManager: manager)
        let loaded = state.loadSavedBoost(for: 7, identifier: "com.test.saved")
        #expect(loaded == .x4)
        #expect(state.getBoost(for: 7) == .x4)
    }

    @Test("loadSavedBoost returns nil when no saved value")
    func loadSavedBoostMissing() {
        let manager = makeManager()
        let state = VolumeState(settingsManager: manager)
        let loaded = state.loadSavedBoost(for: 8, identifier: "com.test.nosave")
        #expect(loaded == nil)
    }

    @Test("All BoostLevel values can be stored and retrieved")
    func allBoostLevels() {
        let state = VolumeState()
        state.setVolume(for: 1, to: 1.0, identifier: "id")
        for (i, level) in BoostLevel.allCases.enumerated() {
            let pid = pid_t(100 + i)
            state.setVolume(for: pid, to: 1.0, identifier: "id.\(i)")
            state.setBoost(for: pid, to: level)
            #expect(state.getBoost(for: pid) == level)
        }
    }
}

// MARK: - Mute

@Suite("VolumeState — Mute")
@MainActor
struct VolumeStateMuteTests {

    @Test("Default mute is false for unknown pid")
    func defaultMute() {
        let state = VolumeState()
        #expect(state.getMute(for: 99) == false)
    }

    @Test("setMute persists via settingsManager")
    func setMutePersists() {
        let manager = makeManager()
        let state = VolumeState(settingsManager: manager)
        state.setMute(for: 1, to: true, identifier: "com.test.mute")
        #expect(state.getMute(for: 1) == true)
        #expect(manager.getMute(for: "com.test.mute") == true)
    }

    @Test("setMute on existing state toggles correctly")
    func setMuteToggle() {
        let state = VolumeState()
        state.setVolume(for: 2, to: 0.5, identifier: "com.test.toggle")
        state.setMute(for: 2, to: true)
        #expect(state.getMute(for: 2) == true)
        state.setMute(for: 2, to: false)
        #expect(state.getMute(for: 2) == false)
    }

    @Test("setMute without existing state creates new state")
    func setMuteCreatesState() {
        let manager = makeManager()
        let state = VolumeState(settingsManager: manager)
        state.setMute(for: 3, to: true, identifier: "com.test.new.mute")
        #expect(state.getMute(for: 3) == true)
    }

    @Test("setMute preserves volume")
    func setMutePreservesVolume() {
        let state = VolumeState()
        state.setVolume(for: 4, to: 0.8, identifier: "com.test.vol")
        state.setMute(for: 4, to: true)
        #expect(state.getVolume(for: 4) == 0.8)
    }

    @Test("loadSavedMute reads from settingsManager")
    func loadSavedMute() {
        let manager = makeManager()
        manager.setMute(for: "com.test.saved.mute", to: true)
        let state = VolumeState(settingsManager: manager)
        let loaded = state.loadSavedMute(for: 5, identifier: "com.test.saved.mute")
        #expect(loaded == true)
        #expect(state.getMute(for: 5) == true)
    }

    @Test("loadSavedMute returns nil when no saved value")
    func loadSavedMuteMissing() {
        let state = VolumeState(settingsManager: makeManager())
        #expect(state.loadSavedMute(for: 9, identifier: "com.missing") == nil)
    }
}

// MARK: - Device Selection Mode

@Suite("VolumeState — Device Selection Mode")
@MainActor
struct VolumeStateDeviceSelectionTests {

    @Test("Default mode is single")
    func defaultModeSingle() {
        let state = VolumeState()
        #expect(state.getDeviceSelectionMode(for: 99) == .single)
    }

    @Test("setDeviceSelectionMode persists to settingsManager")
    func setModePersists() {
        let manager = makeManager()
        let state = VolumeState(settingsManager: manager)
        state.setDeviceSelectionMode(for: 1, to: .multi, identifier: "com.test.mode")
        #expect(state.getDeviceSelectionMode(for: 1) == .multi)
        #expect(manager.getDeviceSelectionMode(for: "com.test.mode") == .multi)
    }

    @Test("Switching from multi back to single")
    func modeRoundTrip() {
        let state = VolumeState()
        state.setVolume(for: 1, to: 1.0, identifier: "id")
        state.setDeviceSelectionMode(for: 1, to: .multi)
        #expect(state.getDeviceSelectionMode(for: 1) == .multi)
        state.setDeviceSelectionMode(for: 1, to: .single)
        #expect(state.getDeviceSelectionMode(for: 1) == .single)
    }

    @Test("loadSavedDeviceSelectionMode reads from settingsManager")
    func loadSavedMode() {
        let manager = makeManager()
        manager.setDeviceSelectionMode(for: "com.test.loadmode", to: .multi)
        let state = VolumeState(settingsManager: manager)
        let loaded = state.loadSavedDeviceSelectionMode(for: 2, identifier: "com.test.loadmode")
        #expect(loaded == .multi)
        #expect(state.getDeviceSelectionMode(for: 2) == .multi)
    }
}

// MARK: - Selected Device UIDs

@Suite("VolumeState — Selected Device UIDs")
@MainActor
struct VolumeStateSelectedDeviceUIDsTests {

    @Test("Default selected UIDs is empty")
    func defaultEmpty() {
        let state = VolumeState()
        #expect(state.getSelectedDeviceUIDs(for: 99).isEmpty)
    }

    @Test("setSelectedDeviceUIDs persists to settingsManager")
    func setUIDsPersists() {
        let manager = makeManager()
        let state = VolumeState(settingsManager: manager)
        let uids: Set<String> = ["uid-A", "uid-B"]
        state.setSelectedDeviceUIDs(for: 1, to: uids, identifier: "com.test.uids")
        #expect(state.getSelectedDeviceUIDs(for: 1) == uids)
        #expect(manager.getSelectedDeviceUIDs(for: "com.test.uids") == uids)
    }

    @Test("Clearing UIDs stores empty set")
    func clearUIDs() {
        let state = VolumeState()
        state.setVolume(for: 1, to: 1.0, identifier: "id")
        state.setSelectedDeviceUIDs(for: 1, to: ["uid-X"])
        state.setSelectedDeviceUIDs(for: 1, to: [])
        #expect(state.getSelectedDeviceUIDs(for: 1).isEmpty)
    }

    @Test("loadSavedSelectedDeviceUIDs reads from settingsManager")
    func loadSavedUIDs() {
        let manager = makeManager()
        manager.setSelectedDeviceUIDs(for: "com.test.load.uids", to: ["uid-1", "uid-2"])
        let state = VolumeState(settingsManager: manager)
        let loaded = state.loadSavedSelectedDeviceUIDs(for: 3, identifier: "com.test.load.uids")
        #expect(loaded == ["uid-1", "uid-2"])
    }
}

// MARK: - Lifecycle

@Suite("VolumeState — Lifecycle")
@MainActor
struct VolumeStateLifecycleTests {

    @Test("removeVolume clears state for pid")
    func removeVolume() {
        let state = VolumeState()
        state.setVolume(for: 1, to: 0.5, identifier: "id")
        state.removeVolume(for: 1)
        #expect(state.getVolume(for: 1) == 1.0) // falls back to default
        #expect(state.getMute(for: 1) == false)
    }

    @Test("cleanup keeps only specified pids")
    func cleanup() {
        let state = VolumeState()
        state.setVolume(for: 1, to: 0.5, identifier: "id1")
        state.setVolume(for: 2, to: 0.6, identifier: "id2")
        state.setVolume(for: 3, to: 0.7, identifier: "id3")
        state.cleanup(keeping: [1, 3])
        #expect(state.getVolume(for: 1) == 0.5) // kept
        #expect(state.getVolume(for: 3) == 0.7) // kept
        #expect(state.getVolume(for: 2) == 1.0) // removed → default
    }

    @Test("resetAll clears all state")
    func resetAll() {
        let state = VolumeState()
        state.setVolume(for: 1, to: 0.3, identifier: "id1")
        state.setMute(for: 2, to: true, identifier: "id2")
        state.setBoost(for: 3, to: .x4, identifier: "id3")
        state.resetAll()
        #expect(state.getVolume(for: 1) == 1.0)
        #expect(state.getMute(for: 2) == false)
        #expect(state.getBoost(for: 3) == .x1)
    }

    @Test("cleanup with empty set removes all pids")
    func cleanupAll() {
        let state = VolumeState()
        state.setVolume(for: 1, to: 0.5, identifier: "id1")
        state.setVolume(for: 2, to: 0.6, identifier: "id2")
        state.cleanup(keeping: [])
        #expect(state.getVolume(for: 1) == 1.0)
        #expect(state.getVolume(for: 2) == 1.0)
    }
}

// MARK: - Helper

@MainActor
private func makeManager() -> SettingsManager {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    return SettingsManager(directory: tempDir)
}
