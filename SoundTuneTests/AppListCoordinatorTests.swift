// SoundTuneTests/AppListCoordinatorTests.swift
import Testing
import Foundation
import AppKit
@testable import SoundTune

// MARK: - Pinning

@Suite("AppListCoordinator — Pinning")
@MainActor
struct AppListCoordinatorPinningTests {

    @Test("pinApp marks app as pinned")
    func pinApp() {
        let (coordinator, _) = make()
        let app = makeApp(pid: 1, bundleID: "com.test.pin")
        coordinator.pinApp(app)
        #expect(coordinator.isPinned(app))
        #expect(coordinator.isPinned(identifier: "com.test.pin"))
    }

    @Test("unpinApp removes pin")
    func unpinApp() {
        let (coordinator, _) = make()
        let app = makeApp(pid: 1, bundleID: "com.test.unpin")
        coordinator.pinApp(app)
        coordinator.unpinApp("com.test.unpin")
        #expect(!coordinator.isPinned(app))
    }

    @Test("pinning same app twice is idempotent")
    func pinIdempotent() {
        let (coordinator, _) = make()
        let app = makeApp(pid: 1, bundleID: "com.test.idem")
        coordinator.pinApp(app)
        coordinator.pinApp(app)
        let infos = coordinator.pinnedAppInfo()
        #expect(infos.filter { $0.persistenceIdentifier == "com.test.idem" }.count == 1)
    }

    @Test("unpinning non-pinned app is a no-op")
    func unpinNonPinned() {
        let (coordinator, _) = make()
        coordinator.unpinApp("com.test.ghost")
        #expect(!coordinator.isPinned(identifier: "com.test.ghost"))
    }

    @Test("pinnedAppInfo preserves displayName and bundleID")
    func pinnedAppInfoFields() {
        let (coordinator, _) = make()
        let app = makeApp(pid: 2, name: "Spotify", bundleID: "com.spotify.client")
        coordinator.pinApp(app)
        let infos = coordinator.pinnedAppInfo()
        let info = infos.first { $0.persistenceIdentifier == "com.spotify.client" }
        #expect(info != nil)
        #expect(info?.displayName == "Spotify")
        #expect(info?.bundleID == "com.spotify.client")
    }

    @Test("app without bundleID uses name-based identifier")
    func nameBasedIdentifier() {
        let (coordinator, _) = make()
        let app = makeApp(pid: 3, name: "UnknownApp", bundleID: nil)
        coordinator.pinApp(app)
        #expect(coordinator.isPinned(identifier: "name:UnknownApp"))
    }
}

// MARK: - Ignoring

@Suite("AppListCoordinator — Ignoring")
@MainActor
struct AppListCoordinatorIgnoringTests {

    @Test("recordIgnore marks app as ignored")
    func recordIgnore() {
        let (coordinator, _) = make()
        let app = makeApp(pid: 1, bundleID: "com.test.ignore")
        coordinator.recordIgnore(app)
        #expect(coordinator.isIgnored(identifier: "com.test.ignore"))
    }

    @Test("clearIgnore removes ignore")
    func clearIgnore() {
        let (coordinator, _) = make()
        let app = makeApp(pid: 1, bundleID: "com.test.clear")
        coordinator.recordIgnore(app)
        coordinator.clearIgnore("com.test.clear")
        #expect(!coordinator.isIgnored(identifier: "com.test.clear"))
    }

    @Test("non-ignored app returns false")
    func nonIgnoredFalse() {
        let (coordinator, _) = make()
        #expect(!coordinator.isIgnored(identifier: "com.test.neverignored"))
    }

    @Test("ignoring a pinned app removes the pin (by design)")
    func ignoreRemovesPin() {
        let (coordinator, _) = make()
        let app = makeApp(pid: 1, bundleID: "com.test.both")
        coordinator.pinApp(app)
        #expect(coordinator.isPinned(app))
        coordinator.recordIgnore(app)
        #expect(!coordinator.isPinned(app), "Ignoring should remove the pin")
        #expect(coordinator.isIgnored(identifier: "com.test.both"))
    }
}

// MARK: - Inactive App Settings

@Suite("AppListCoordinator — Inactive Volume & Boost")
@MainActor
struct AppListCoordinatorVolumeBoostTests {

    @Test("getVolumeForInactive returns defaultNewAppVolume when unset")
    func defaultVolume() {
        let (coordinator, manager) = make()
        let vol = coordinator.getVolumeForInactive(identifier: "com.test.novol")
        #expect(vol == manager.appSettings.defaultNewAppVolume)
    }

    @Test("setVolumeForInactive persists and getVolumeForInactive reads it back")
    func setGetVolume() {
        let (coordinator, _) = make()
        coordinator.setVolumeForInactive(identifier: "com.test.vol", to: 0.42)
        #expect(abs(coordinator.getVolumeForInactive(identifier: "com.test.vol") - 0.42) < 1e-5)
    }

    @Test("getBoostForInactive returns .x1 when unset")
    func defaultBoost() {
        let (coordinator, _) = make()
        #expect(coordinator.getBoostForInactive(identifier: "com.test.noboost") == .x1)
    }

    @Test("setBoostForInactive persists and getBoostForInactive reads it back")
    func setGetBoost() {
        let (coordinator, _) = make()
        coordinator.setBoostForInactive(identifier: "com.test.boost", to: .x3)
        #expect(coordinator.getBoostForInactive(identifier: "com.test.boost") == .x3)
    }
}

@Suite("AppListCoordinator — Inactive Mute & EQ")
@MainActor
struct AppListCoordinatorMuteEQTests {

    @Test("getMuteForInactive returns false when unset")
    func defaultMute() {
        let (coordinator, _) = make()
        #expect(coordinator.getMuteForInactive(identifier: "com.test.nomute") == false)
    }

    @Test("setMuteForInactive persists")
    func setGetMute() {
        let (coordinator, _) = make()
        coordinator.setMuteForInactive(identifier: "com.test.mute", to: true)
        #expect(coordinator.getMuteForInactive(identifier: "com.test.mute") == true)
    }

    @Test("setEQSettingsForInactive round-trips correctly")
    func setGetEQ() {
        let (coordinator, _) = make()
        var eq = EQSettings()
        eq.bandGains[0] = 6.0
        eq.bandGains[9] = -3.0
        coordinator.setEQSettingsForInactive(eq, identifier: "com.test.eq")
        let loaded = coordinator.getEQSettingsForInactive(identifier: "com.test.eq")
        #expect(loaded.bandGains[0] == 6.0)
        #expect(loaded.bandGains[9] == -3.0)
    }
}

@Suite("AppListCoordinator — Inactive Device Routing")
@MainActor
struct AppListCoordinatorRoutingTests {

    @Test("isFollowingDefaultForInactive is true when unset")
    func defaultFollowsDefault() {
        let (coordinator, _) = make()
        #expect(coordinator.isFollowingDefaultForInactive(identifier: "com.test.noroute"))
    }

    @Test("setDeviceRoutingForInactive with UID stops following default")
    func setRoutingUID() {
        let (coordinator, _) = make()
        coordinator.setDeviceRoutingForInactive(identifier: "com.test.route", deviceUID: "UID-X")
        #expect(coordinator.getDeviceRoutingForInactive(identifier: "com.test.route") == "UID-X")
        #expect(!coordinator.isFollowingDefaultForInactive(identifier: "com.test.route"))
    }

    @Test("setDeviceRoutingForInactive with nil restores follow-default")
    func clearRoutingRestoresDefault() {
        let (coordinator, _) = make()
        coordinator.setDeviceRoutingForInactive(identifier: "com.test.reset", deviceUID: "UID-Y")
        coordinator.setDeviceRoutingForInactive(identifier: "com.test.reset", deviceUID: nil)
        #expect(coordinator.isFollowingDefaultForInactive(identifier: "com.test.reset"))
    }

    @Test("setDeviceSelectionModeForInactive round-trips")
    func deviceSelectionMode() {
        let (coordinator, _) = make()
        coordinator.setDeviceSelectionModeForInactive(identifier: "com.test.dsm", to: .multi)
        #expect(coordinator.getDeviceSelectionModeForInactive(identifier: "com.test.dsm") == .multi)
    }

    @Test("setSelectedDeviceUIDsForInactive round-trips")
    func selectedDeviceUIDs() {
        let (coordinator, _) = make()
        let uids: Set<String> = ["uid-1", "uid-2", "uid-3"]
        coordinator.setSelectedDeviceUIDsForInactive(identifier: "com.test.uids", to: uids)
        #expect(coordinator.getSelectedDeviceUIDsForInactive(identifier: "com.test.uids") == uids)
    }

    @Test("getSelectedDeviceUIDsForInactive returns empty set when unset")
    func defaultSelectedUIDs() {
        let (coordinator, _) = make()
        #expect(coordinator.getSelectedDeviceUIDsForInactive(identifier: "com.test.nouids").isEmpty)
    }
}

// MARK: - Helpers

@MainActor
private func make() -> (AppListCoordinator, SettingsManager) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let manager = SettingsManager(directory: dir)
    return (AppListCoordinator(settingsManager: manager), manager)
}

@MainActor
private func makeApp(pid: pid_t, name: String = "TestApp", bundleID: String?) -> AudioApp {
    AudioApp(
        id: pid,
        processObjectIDs: [],
        name: name,
        icon: .init(),
        bundleID: bundleID
    )
}
