import Testing
import Foundation
@testable import SoundTune

@Suite("VolumeState — normalization")
@MainActor
struct VolumeStateNormalizationTests {

    @Test("Runtime app volume is clamped to slider range")
    func runtimeVolumeClamps() {
        let manager = makeManager()
        let state = VolumeState(settingsManager: manager)
        let pid: pid_t = 42
        let identifier = "com.test.volume-state"

        state.setVolume(for: pid, to: 2.5, identifier: identifier)
        #expect(state.getVolume(for: pid) == 1.0)
        #expect(manager.getVolume(for: identifier) == 1.0)

        state.setVolume(for: pid, to: -0.5, identifier: identifier)
        #expect(state.getVolume(for: pid) == 0.0)
        #expect(manager.getVolume(for: identifier) == 0.0)

        state.setVolume(for: pid, to: .nan, identifier: identifier)
        #expect(state.getVolume(for: pid) == 1.0)
        #expect(manager.getVolume(for: identifier) == 1.0)
    }

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }
}
