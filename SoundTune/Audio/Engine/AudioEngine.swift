// SoundTune/Audio/Engine/AudioEngine.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@Observable
@MainActor
final class AudioEngine {
    let processMonitor: any AudioProcessMonitoring
    let deviceMonitor: any AudioDeviceProviding
    let bluetoothDeviceMonitor: BluetoothDeviceMonitor
    let deviceVolumeMonitor: any DeviceVolumeProviding
    let volumeState: VolumeState
    let settingsManager: SettingsManager
    let autoEQProfileManager: AutoEQProfileManager
    let permission: AudioRecordingPermission
    let bluetoothPermission: BluetoothPermission
    let appListCoordinator: AppListCoordinator

    #if !APP_STORE
    let ddcController: DDCController
    #endif

    var taps: [pid_t: any ProcessTapControlling] = [:]

    /// Factory for creating tap controllers. Overridable for testing.
    let tapFactory: @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling

    /// Closure to check if a device is alive. Overridable for testing.
    let isAliveCheck: (AudioDeviceID) -> Bool

    /// One-shot HAL listeners for devices that were present but not alive during priority resolution.
    /// Keyed by AudioDeviceID. Each entry holds the device UID, listener block, and a timeout task.
    var aliveWatchers: [AudioDeviceID: (uid: String, block: AudioObjectPropertyListenerBlock, timeout: Task<Void, Never>)] = [:]

    /// Number of pending alive watchers (exposed for testing).
    var pendingAliveWatcherCount: Int { aliveWatchers.count }

    var appliedPIDs: Set<pid_t> = []
    var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    var followsDefault: Set<pid_t> = []  // Apps that follow system default
    /// The last output default confirmed by SoundTune (user change or programmatic switch).
    /// Used to restore after macOS auto-switches to a lower-priority device.
    var lastConfirmedDefaultUID: String?
    /// Timestamp of the last auto-switch override. Used to distinguish rapid BT auto-switches
    /// (< 1s apart) from deliberate user changes (> 1s after last override).
    var lastAutoSwitchOverrideTime: Date?
    var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    var staleCleanupTask: Task<Void, Never>?  // Debounced cleanup scheduling
    var healthMonitorTask: Task<Void, Never>?  // Periodic tap health monitor
    var tapRecoveryCooldownUntil: [pid_t: Date] = [:]  // Prevents tap recreation thrashing
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SoundTune", category: "AudioEngine")

    // MARK: - HUD event hooks (set by SoundTuneApp to forward events to HUDWindowController)

    /// Called when an output device connects. Argument is the device name.
    var onDeviceConnectedHUD: ((String) -> Void)?
    /// Called when an output device disconnects. Argument is the device name.
    var onDeviceDisconnectedHUD: ((String) -> Void)?
    /// Called when the mute state of the default output device changes externally.
    /// Arguments: device name, isMuted.
    var onDefaultDeviceMuteChangedHUD: ((String, Bool) -> Void)?

    // MARK: - Priority State Machine

    /// Tracks whether we're waiting for macOS to potentially auto-switch after a device connect.
    enum PriorityState {
        case stable
        case pendingAutoSwitch(connectedDeviceUID: String, timeoutTask: Task<Void, Never>)
    }

    var outputPriorityState: PriorityState = .stable
    var inputPriorityState: PriorityState = .stable

    /// Grace period for auto-switch detection (wired devices)
    let autoSwitchGracePeriod: TimeInterval = 2.0

    /// Extended grace period for Bluetooth devices (firmware handshake takes longer)
    let btAutoSwitchGracePeriod: TimeInterval = 5.0

    // MARK: - Echo Suppression

    let outputEchoTracker = EchoTracker(label: "Output")
    let inputEchoTracker = EchoTracker(label: "Input")

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
        deviceVolumeMonitor.outputVolumeBackend(for: deviceID)
    }

    var inputDevices: [AudioDevice] {
        deviceMonitor.inputDevices
    }

    /// Output devices sorted by user-defined priority order.
    /// Devices in the priority list appear in that order; new/unknown devices are appended alphabetically.
    var prioritySortedOutputDevices: [AudioDevice] {
        let devices = outputDevices.filter(isValidAudioDevice)
        let priorityOrder = settingsManager.devicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        // Collect devices in priority order (skip stale UIDs)
        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        // Append new devices alphabetically
        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Input devices sorted by user-defined priority order.
    var prioritySortedInputDevices: [AudioDevice] {
        let devices = inputDevices.filter(isValidAudioDevice)
        let priorityOrder = settingsManager.inputDevicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    private func isValidAudioDevice(_ device: AudioDevice) -> Bool {
        if device.id.isBluetoothDevice() {
            let pairedDevices = bluetoothDeviceMonitor.pairedDevices
            guard !pairedDevices.isEmpty else { return true }

            let pairedAudioDevices = bluetoothDeviceMonitor.pairedAudioDevices
            guard !pairedAudioDevices.isEmpty else { return true }

            return pairedAudioDevices.contains { paired in
                paired.name.localizedCaseInsensitiveCompare(device.name) == .orderedSame ||
                device.name.localizedStandardContains(paired.name) ||
                paired.name.localizedStandardContains(device.name)
            }
        }
        return true
    }

    /// Registers any output devices not yet in the priority list.
    /// Call this when devices change (not from computed properties).
    func registerNewDevicesInPriority() {
        for device in outputDevices {
            settingsManager.ensureDeviceInPriority(device.uid)
        }
        for device in inputDevices {
            settingsManager.ensureInputDeviceInPriority(device.uid)
        }
    }

    /// Returns the highest-priority device that is both connected and alive.
    /// `isDeviceAlive()` is checked internally — callers never need to check separately.
    static func resolveHighestPriority(
        priorityOrder: [String],
        connectedDevices: [AudioDevice],
        excluding: String? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil
    ) -> AudioDevice? {
        let aliveCheck = isAlive ?? { $0.isDeviceAlive() }
        let connected = Dictionary(
            connectedDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for uid in priorityOrder {
            guard uid != excluding,
                  let device = connected[uid],
                  aliveCheck(device.id) else { continue }
            return device
        }
        // Fallback: any alive connected device not excluded
        return connectedDevices.first {
            $0.uid != excluding && aliveCheck($0.id)
        }
    }

    init(
        permission: AudioRecordingPermission,
        bluetoothPermission: BluetoothPermission = BluetoothPermission(),
        settingsManager: SettingsManager,
        autoEQProfileManager: AutoEQProfileManager,
        deviceProvider: (any AudioDeviceProviding)? = nil,
        processMonitor: (any AudioProcessMonitoring)? = nil,
        deviceVolumeMonitor: (any DeviceVolumeProviding)? = nil,
        tapFactory: (@MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling)? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil,
        startMonitorsAutomatically: Bool = true
    ) {
        self.permission = permission
        self.bluetoothPermission = bluetoothPermission
        let manager = settingsManager
        self.settingsManager = manager
        self.appListCoordinator = AppListCoordinator(settingsManager: manager)
        self.autoEQProfileManager = autoEQProfileManager
        self.volumeState = VolumeState(settingsManager: manager)
        self.isAliveCheck = isAlive ?? { $0.isDeviceAlive() }

        // If a custom deviceProvider is given, use it directly.
        // Otherwise create a real AudioDeviceMonitor (needed by DeviceVolumeMonitor and default tap factory).
        let realDeviceMonitor: AudioDeviceMonitor?
        if let provider = deviceProvider {
            realDeviceMonitor = provider as? AudioDeviceMonitor
            self.deviceMonitor = provider
        } else {
            let monitor = AudioDeviceMonitor()
            realDeviceMonitor = monitor
            self.deviceMonitor = monitor
        }
        self.processMonitor = processMonitor ?? AudioProcessMonitor()
        self.bluetoothDeviceMonitor = BluetoothDeviceMonitor()

        #if !APP_STORE
        let ddc = DDCController(settingsManager: manager)
        self.ddcController = ddc
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager, ddcController: ddc)
        }
        #else
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager)
        }
        #endif

        // Tap factory: use provided factory or default to ProcessTapController
        if let factory = tapFactory {
            self.tapFactory = factory
        } else {
            self.tapFactory = { app, deviceUIDs, preferredSource in
                if deviceUIDs.count == 1 {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUID: deviceUIDs[0],
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                } else {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUIDs: deviceUIDs,
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                }
            }
        }

        outputEchoTracker.onTimeout = { [weak self] _ in
            self?.restoreConfirmedDefault()
        }
        inputEchoTracker.onTimeout = { [weak self] _ in
            guard let self, self.settingsManager.appSettings.lockInputDevice else { return }
            self.restoreLockedInputDevice()
        }

        // Wire callbacks — needed for both test and production mode
        wireCallbacks()

        #if !APP_STORE
        ddc.onProbeCompleted = { [weak self] in
            self?.deviceVolumeMonitor.refreshAfterDDCProbe()
            self?.refreshAllTapOutputStates()
        }
        #endif

        if startMonitorsAutomatically {
            Task { @MainActor in
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                }
                self.deviceMonitor.start()
                if self.bluetoothPermission.status == .authorized {
                    self.bluetoothDeviceMonitor.start()
                }

                #if !APP_STORE
                ddc.start()
                #endif

                // Start device volume monitor AFTER deviceMonitor.start() populates devices
                self.deviceVolumeMonitor.start()

                self.applyPersistedSettings()
                self.registerNewDevicesInPriority()
                // Seed the confirmed default from whatever macOS has at startup
                self.lastConfirmedDefaultUID = self.deviceVolumeMonitor.defaultDeviceUID
                if manager.appSettings.lockInputDevice {
                    self.restoreLockedInputDevice()
                }
            }
        }

        // Start process monitor when permission is granted
        if startMonitorsAutomatically && permission.status != .authorized {
            observePermissionGranted()
        }
        // Start bluetooth monitor when bluetooth permission is granted
        if startMonitorsAutomatically && bluetoothPermission.status != .authorized {
            observeBluetoothPermissionGranted()
        }
    }

    private func observePermissionGranted() {
        withObservationTracking {
            _ = self.permission.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                    self.applyPersistedSettings()
                    self.startHealthMonitor()
                    self.logger.info("Audio capture authorized — process monitor started")
                } else {
                    self.observePermissionGranted()
                }
            }
        }
    }

    private func observeBluetoothPermissionGranted() {
        withObservationTracking {
            _ = self.bluetoothPermission.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.bluetoothPermission.status == .authorized {
                    self.bluetoothDeviceMonitor.start()
                    self.logger.info("Bluetooth authorized — bluetooth monitor started")
                } else {
                    self.observeBluetoothPermissionGranted()
                }
            }
        }
    }

    /// Wire all event callbacks from monitors to AudioEngine handlers.
    private func wireCallbacks() {
        // Sync device volume changes to taps for VU meter accuracy
        deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            let loudnessEnabled = self.settingsManager.appSettings.loudnessCompensationEnabled
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.currentDeviceVolume = newVolume
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                    tap.updateLoudnessCompensation(
                        volume: self.effectiveLoudnessVolume(for: tap),
                        enabled: loudnessEnabled
                    )
                }
            }
        }

        deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.isDeviceMuted = isMuted
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                }
            }
            // Show HUD for mute changes on the default output device
            if deviceID == self.deviceVolumeMonitor.defaultDeviceID {
                let deviceName = self.deviceMonitor.outputDevices
                    .first(where: { $0.id == deviceID })?.name ?? ""
                self.onDefaultDeviceMuteChangedHUD?(deviceName, isMuted)
            }
        }

        processMonitor.onAppsChanged = { [weak self] apps in
            self?.applyPersistedSettings()
            self?.scheduleStaleCleanup()
        }

        // Priority order closures — only for concrete AudioDeviceMonitor
        if let realMonitor = deviceMonitor as? AudioDeviceMonitor {
            realMonitor.outputPriorityOrder = { [weak self] in
                self?.settingsManager.devicePriorityOrder ?? []
            }
            realMonitor.inputPriorityOrder = { [weak self] in
                self?.settingsManager.inputDevicePriorityOrder ?? []
            }
            realMonitor.onBTDeviceSampleRateChanged = { [weak self] uid, newRate in
                Task { @MainActor [weak self] in
                    await self?.handleBTDeviceSampleRateChanged(uid: uid, newRate: newRate)
                }
            }
        }

        deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.refresh()
        }

        deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceConnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.notifyDeviceAppearedInCoreAudio()
        }

        deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
            self?.handleInputDeviceDisconnected(deviceUID)
        }

        deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
            self?.settingsManager.ensureInputDeviceInPriority(deviceUID)
            self?.handleInputDeviceConnected(deviceUID, name: deviceName)
        }

        deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] newDefaultUID in
            self?.handleDefaultDeviceChanged(newDefaultUID)
        }

        deviceVolumeMonitor.onDefaultInputDeviceChanged = { [weak self] newDefaultInputUID in
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChanged(newDefaultInputUID)
            }
        }
    }

    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    func start() {
        // Monitors have internal guards against double-starting
        if permission.status == .authorized {
            processMonitor.start()
        }
        deviceMonitor.start()
        if bluetoothPermission.status == .authorized {
            bluetoothDeviceMonitor.start()
        }
        #if !APP_STORE
        ddcController.start()
        #endif
        deviceVolumeMonitor.start()
        applyPersistedSettings()
        registerNewDevicesInPriority()
        if permission.status == .authorized {
            startHealthMonitor()
        }

        // Restore locked input device if feature is enabled
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }

        logger.info("AudioEngine started")
    }

    func stop() {
        stopHealthMonitor()
        processMonitor.stop()
        deviceMonitor.stop()
        bluetoothDeviceMonitor.stop()
        #if !APP_STORE
        ddcController.stop()
        #endif
        deviceVolumeMonitor.stop()
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        logger.info("AudioEngine stopped")
    }

    /// Explicit shutdown for app termination. Ensures all listeners are cleaned up.
    /// Call from applicationWillTerminate or equivalent lifecycle hook.
    /// Note: For menu bar apps, process exit cleans up resources anyway, so this is optional.
    func shutdown() {
        stop()
        logger.info("AudioEngine shutdown complete")
    }

    /// Effective gain for ProcessTapController: app volume × boost, plus optional
    /// single-device software output gain for software-backed devices.
    /// Single-device-routed apps on `.software`-backed devices always receive the
    /// device's software gain; multi-destination routing keeps `appGain` alone
    /// because per-device software gain has no unambiguous meaning across fan-out.
    internal func effectiveVolume(for pid: pid_t, deviceUIDs: [String]? = nil) -> Float {
        let appGain = volumeState.getVolume(for: pid) * volumeState.getBoost(for: pid).rawValue

        guard let resolvedUIDs = deviceUIDs, resolvedUIDs.count == 1,
              let primaryUID = resolvedUIDs.first,
              let device = deviceMonitor.device(for: primaryUID),
              outputVolumeBackend(for: device.id) == .software else {
            return appGain
        }

        return appGain * deviceVolumeMonitor.outputProcessingGain(for: device.id)
    }

    /// Estimated listening level for loudness compensation: device volume × per-app slider.
    /// Does not include boost (intentional amplification beyond reference).
    /// The compensator's phon estimation clamps to [0,1] so values > 1 are treated as reference.
    internal func effectiveLoudnessVolume(for tap: any ProcessTapControlling) -> Float {
        tap.currentDeviceVolume * volumeState.getVolume(for: tap.app.id)
    }

    internal func applyTapOutputState(to tap: any ProcessTapControlling, for pid: pid_t, deviceUIDs: [String]? = nil) {
        let resolvedUIDs = deviceUIDs ?? tap.currentDeviceUIDs
        tap.volume = effectiveVolume(for: pid, deviceUIDs: resolvedUIDs)
        tap.isMuted = volumeState.getMute(for: pid)

        if let primaryUID = resolvedUIDs.first,
           let device = deviceMonitor.device(for: primaryUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        } else {
            tap.currentDeviceVolume = 1.0
            tap.isDeviceMuted = false
        }
    }

    internal func refreshAllTapOutputStates() {
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }
}

// MARK: - URLHandlerEngine Conformance

extension AudioEngine: URLHandlerEngine {}
