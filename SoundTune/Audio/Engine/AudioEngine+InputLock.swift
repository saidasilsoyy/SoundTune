// SoundTune/Audio/Engine/AudioEngine+InputLock.swift
import AudioToolbox
import Foundation
import os

@MainActor
extension AudioEngine {
    // MARK: - Input Device Lock

    /// Handles changes to the default input device.
    /// Uses state machine to distinguish auto-switch (from device connection) vs user action.
    internal func handleDefaultInputDeviceChanged(_ newDefaultInputUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after input device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = inputPriorityState {
            if newDefaultInputUID == pendingUID, settingsManager.appSettings.lockInputDevice {
                // Case 1: macOS auto-switched to the newly connected device — restore locked device.
                // Re-enter PENDING_AUTOSWITCH because macOS may auto-switch multiple times.
                timeoutTask.cancel()
                restoreLockedInputDevice()
                let transport = deviceMonitor.inputDevice(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.inputPriorityState = .stable
                    self.logger.debug("Input auto-switch grace period expired after override")
                }
                inputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }
            // Case 2: Our own echo from the override. Consume without disrupting state machine.
            if inputEchoTracker.consume(newDefaultInputUID) {
                return
            }
            // Case 3: Genuine user intent — respect it.
            timeoutTask.cancel()
            inputPriorityState = .stable
        }

        // Suppress echo from our own input device override (when not in pendingAutoSwitch)
        if inputEchoTracker.consume(newDefaultInputUID) {
            return
        }

        // If any input echo counter is pending, skip routing
        if inputEchoTracker.hasPending {
            logger.debug("Skipping input routing — echo pending")
            return
        }

        // If lock is disabled, let system control input freely
        guard settingsManager.appSettings.lockInputDevice else { return }

        // Restore the locked device — any change outside SoundTune's UI is either
        // macOS auto-switch or System Settings, and the lock should hold either way.
        // Users change the lock via SoundTune's UI (setLockedInputDevice).
        guard let lockedUID = settingsManager.lockedInputDeviceUID else { return }
        if newDefaultInputUID != lockedUID {
            restoreLockedInputDevice()
        }
    }

    /// Restores the locked input device, or falls back to built-in mic if unavailable.
    internal func restoreLockedInputDevice() {
        guard let lockedUID = settingsManager.lockedInputDeviceUID,
              let lockedDevice = deviceMonitor.inputDevice(for: lockedUID) else {
            // No locked device or it's unavailable - fall back to built-in
            lockToBuiltInMicrophone()
            return
        }

        // Don't restore if already on the locked device
        guard deviceVolumeMonitor.defaultInputDeviceUID != lockedUID else { return }

        logger.info("Restoring locked input device: \(lockedDevice.name)")
        if deviceVolumeMonitor.setDefaultInputDevice(lockedDevice.id) {
            inputEchoTracker.increment(lockedDevice.uid)
        }
    }

    /// Locks the input device to the built-in microphone.
    /// This is a fallback — does NOT update preferredInputDeviceUID.
    internal func lockToBuiltInMicrophone() {
        guard let builtInMic = deviceMonitor.inputDevices.first(where: {
            $0.id.readTransportType() == .builtIn
        }) else {
            logger.warning("No built-in microphone found")
            return
        }

        applyInputDeviceLock(builtInMic)
    }

    /// Applies input device lock without changing the user's preferred device.
    /// Used for fallback scenarios (disconnect, built-in mic recovery).
    internal func applyInputDeviceLock(_ device: AudioDevice) {
        logger.info("Locking input device to: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when the user toggles lockInputDevice ON in settings.
    /// Captures the current default input device as the locked and preferred device.
    func handleInputLockEnabled() {
        guard let currentUID = deviceVolumeMonitor.defaultInputDeviceUID,
              let device = deviceMonitor.inputDevice(for: currentUID) else {
            return
        }
        logger.info("Input lock enabled, locking to current default: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)
    }

    /// Called when user explicitly selects an input device (via SoundTune UI).
    /// Persists the choice and applies the change.
    func setLockedInputDevice(_ device: AudioDevice) {
        logger.info("User locked input device to: \(device.name)")

        // Persist the choice — both current lock and preferred (user intent)
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)

        // Apply the change
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when an input device connects — restores locked/preferred device and guards against auto-switch.
    internal func handleInputDeviceConnected(_ deviceUID: String, name deviceName: String) {
        guard settingsManager.appSettings.lockInputDevice else { return }

        // If the reconnected device is the user's preferred device, restore the lock to it
        if let preferredUID = settingsManager.preferredInputDeviceUID,
           deviceUID == preferredUID,
           settingsManager.lockedInputDeviceUID != preferredUID,
           let device = deviceMonitor.inputDevice(for: deviceUID) {
            logger.info("Preferred input device reconnected: \(deviceName), restoring lock")
            settingsManager.setLockedInputDeviceUID(device.uid)
        }

        // Restore the user's locked device (not priority-based — lock overrides priority)
        restoreLockedInputDevice()

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one
        if case .pendingAutoSwitch(_, let oldTask) = inputPriorityState {
            oldTask.cancel()
        }

        // Always enter PENDING_AUTOSWITCH — macOS may auto-switch to the newly connected
        // device multiple times during BT handshake, even if we just restored the lock.
        let transport = deviceMonitor.inputDevice(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.inputPriorityState = .stable
            self.logger.debug("Input auto-switch grace period expired, no macOS switch detected")
        }

        inputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
    }

    /// Handles input device disconnect — uses priority fallback, then built-in mic.
    internal func handleInputDeviceDisconnected(_ deviceUID: String) {
        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = inputPriorityState, uid == deviceUID {
            task.cancel()
            inputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultInput = deviceUID == deviceVolumeMonitor.defaultInputDeviceUID

        let priorityFallback = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        // If the disconnected device was the default input, override to priority fallback
        if wasDefaultInput {
            reEvaluateInputDefault(excluding: deviceUID)
        }

        // If the locked device disconnected, update the lock to the fallback (or built-in mic)
        guard settingsManager.appSettings.lockInputDevice,
              settingsManager.lockedInputDeviceUID == deviceUID else { return }

        if let fallbackDevice = priorityFallback {
            logger.info("Locked input device disconnected, falling back to priority: \(fallbackDevice.name)")
            if wasDefaultInput {
                // Default already switched above, just update the lock setting
                settingsManager.setLockedInputDeviceUID(fallbackDevice.uid)
            } else {
                applyInputDeviceLock(fallbackDevice)
            }
        } else {
            logger.info("Locked input device disconnected, falling back to built-in mic")
            lockToBuiltInMicrophone()
        }
    }
}
