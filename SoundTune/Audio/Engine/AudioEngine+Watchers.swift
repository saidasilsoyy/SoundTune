// SoundTune/Audio/Engine/AudioEngine+Watchers.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@MainActor
extension AudioEngine {
    // MARK: - Alive Watchers

    /// Installs a one-shot HAL listener for kAudioDevicePropertyDeviceIsAlive on a device
    /// that is present but not yet alive. When the device becomes alive, re-runs
    /// handleDeviceConnected so priority is re-evaluated. Self-removes after firing or timeout.
    internal func installAliveWatcher(deviceID: AudioDeviceID, uid: String, name: String) {
        guard aliveWatchers[deviceID] == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAliveCheck(deviceID) else { return }
                self.logger.info("Device became alive: \(name) (\(uid)), re-evaluating priority")
                self.removeAliveWatcher(deviceID)
                self.handleDeviceConnected(uid, name: name)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        guard status == noErr else {
            logger.warning("Failed to install alive watcher for \(name) (\(deviceID)): \(status)")
            return
        }

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            self.logger.debug("Alive watcher timed out for \(name) (\(uid))")
            self.removeAliveWatcher(deviceID)
        }

        aliveWatchers[deviceID] = (uid: uid, block: block, timeout: timeoutTask)
        logger.debug("Installed alive watcher for \(name) (\(uid))")
    }

    /// Removes a one-shot alive watcher by device ID, cleaning up the HAL listener and timeout.
    internal func removeAliveWatcher(_ deviceID: AudioDeviceID) {
        guard let watcher = aliveWatchers.removeValue(forKey: deviceID) else { return }
        watcher.timeout.cancel()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, watcher.block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove alive watcher for device \(deviceID): \(status)")
        }
    }

    /// Removes a one-shot alive watcher by device UID. Used during disconnect when the
    /// device is already removed from the monitor's list and device(for:) returns nil.
    internal func removeAliveWatcher(forUID uid: String) {
        guard let (deviceID, _) = aliveWatchers.first(where: { $0.value.uid == uid }) else { return }
        removeAliveWatcher(deviceID)
    }

    internal func showReconnectNotification(deviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = t("Audio Device Reconnected")
        content.body = String(format: t("\"%@\" is back. %d app(s) switched back."), deviceName, affectedApps.count)
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-reconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    internal func showDisconnectNotification(deviceName: String, fallbackName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = t("Audio Device Disconnected")
        content.body = String(format: t("\"%@\" disconnected. %d app(s) switched to %@"), deviceName, affectedApps.count, fallbackName)
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-disconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Called when system default output device changes - switches apps that follow default
    internal func handleDefaultDeviceChanged(_ newDefaultUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after a device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = outputPriorityState {
            // Check echoes FIRST — SoundTune's own changes (UI, restoreConfirmedDefault)
            // create echoes. Consuming before Case 1 ensures SoundTune UI changes aren't
            // mistaken for macOS auto-switches.
            if outputEchoTracker.consume(newDefaultUID) {
                return
            }

            if newDefaultUID == pendingUID {
                // Settling heuristic: if >1s since last override, BT auto-switches have
                // settled. This is likely the user changing via System Settings — accept it.
                // BT auto-switches happen within ms; user actions take >1s.
                if let lastOverride = lastAutoSwitchOverrideTime,
                   Date().timeIntervalSince(lastOverride) > 1.0 {
                    timeoutTask.cancel()
                    outputPriorityState = .stable
                    lastConfirmedDefaultUID = newDefaultUID
                    lastAutoSwitchOverrideTime = nil
                    routeFollowsDefaultApps(to: newDefaultUID)
                    let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? newDefaultUID
                    logger.info("Accepted user change to \(deviceName) (settled >1s)")
                    return
                }

                // Case 1: macOS auto-switched to the newly connected device — restore what
                // the user was on. Re-enter PENDING_AUTOSWITCH for further auto-switches.
                timeoutTask.cancel()
                restoreConfirmedDefault()
                lastAutoSwitchOverrideTime = Date()
                let transport = deviceMonitor.device(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.outputPriorityState = .stable
                    self.lastAutoSwitchOverrideTime = nil
                    self.logger.debug("Auto-switch grace period expired after override")
                }
                outputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }

            // Case 3: Genuine user intent (different device, not our echo) — respect it.
            timeoutTask.cancel()
            outputPriorityState = .stable
            lastAutoSwitchOverrideTime = nil
        }

        // Suppress echo from our own priority-based override (when not in pendingAutoSwitch)
        if outputEchoTracker.consume(newDefaultUID) {
            return
        }

        // If any echo counter is pending, another override is in flight — skip interim routing
        if outputEchoTracker.hasPending {
            logger.debug("Skipping followsDefault routing — echo pending")
            return
        }

        // Check if the new default device is known and alive.
        guard let newDevice = deviceMonitor.device(for: newDefaultUID) else {
            // Device not yet in monitor's list (e.g., BT device default-changed before device-list
            // notification). Defer — the upcoming handleDeviceConnected will enforce priority.
            logger.debug("Default changed to unknown device \(newDefaultUID), deferring to device list refresh")
            return
        }

        let newDeviceIsAlive = isAliveCheck(newDevice.id)

        if !newDeviceIsAlive {
            // Dead device became default (race with disconnect) — override to priority fallback
            reEvaluateOutputDefault()
        } else {
            // Genuine change to a live device — route followsDefault apps
            lastConfirmedDefaultUID = newDefaultUID
            routeFollowsDefaultApps(to: newDefaultUID)

            let affectedApps = apps.filter { followsDefault.contains($0.id) }
            if !affectedApps.isEmpty {
                let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? "Default Output"
                logger.info("Default changed to \(deviceName), \(affectedApps.count) app(s) following")
                if settingsManager.appSettings.showDeviceDisconnectAlerts {
                    showDefaultChangedNotification(newDeviceName: deviceName, affectedApps: affectedApps)
                }
            }
        }
    }

    private func showDefaultChangedNotification(newDeviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = t("Default Audio Device Changed")
        content.body = String(format: t("%d app(s) switched to \"%@\""), affectedApps.count, newDeviceName)
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "default-device-changed",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Returns the preferred tap source device UID for stream-specific capture.
    /// Only follows-default apps use stream-specific taps (multichannel preserved, tap always
    /// valid because the app switches device when default changes). Explicitly-routed apps
    /// always use stereo mixdown (nil) — their tap never goes stale when the default changes.
    internal func preferredTapSourceDeviceUID(forOutputUIDs outputUIDs: [String], isFollowsDefault: Bool) -> String? {
        guard isFollowsDefault else { return nil }
        guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else { return nil }
        return outputUIDs.contains(defaultUID) ? defaultUID : nil
    }

    private func cleanupStaleTaps() {
        let activePIDs = Set(apps.map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // Cancel cleanup for PIDs that reappeared — but only if bundleID matches.
        // PID reuse by a different app should not rescue the old tap.

        for pid in activePIDs {
            guard let task = pendingCleanup[pid] else { continue }

            let reappearedApp = apps.first { $0.id == pid }
            let existingTap = taps[pid]

            if let reappearedApp, let existingTap,
               reappearedApp.bundleID != existingTap.app.bundleID {
                // PID was reused by a different app — let the old tap be destroyed
                logger.debug("PID \(pid) reused by different app (\(reappearedApp.bundleID ?? "nil") vs \(existingTap.app.bundleID ?? "nil")), not cancelling cleanup")
                continue
            }

            pendingCleanup.removeValue(forKey: pid)
            task.cancel()
            // Don't remove from appliedPIDs — the tap is still alive and the aggregate
            // device is still running. The process just transiently stopped audio I/O
            // during a device change (kAudioProcessPropertyIsRunning flicker).
            // Device routing is already handled by routeFollowsDefaultApps (follows-default)
            // or stays put (explicit routing). Re-processing would cause an unnecessary
            // crossfade that interrupts audio.
            logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared")
        }

        // Schedule cleanup for newly stale PIDs (with grace period)
        for pid in stalePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            pendingCleanup[pid] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }

                // Double-check still stale
                let currentPIDs = Set(self.apps.map { $0.id })
                guard !currentPIDs.contains(pid) else {
                    self.pendingCleanup.removeValue(forKey: pid)
                    return
                }

                // Now safe to cleanup
                if let tap = self.taps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.logger.debug("Cleaned up stale tap for PID \(pid)")
                }
                self.appDeviceRouting.removeValue(forKey: pid)
                self.followsDefault.remove(pid)
                self.appliedPIDs.remove(pid)  // Allow re-initialization if app resumes
                self.pendingCleanup.removeValue(forKey: pid)
            }
        }

        // Include pending PIDs in cleanup exclusion to avoid premature state cleanup
        let pidsToKeep = activePIDs.union(Set(pendingCleanup.keys))
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        followsDefault = followsDefault.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }

    /// Debounced stale tap cleanup — coalesces rapid app-list changes into a single cleanup pass.
    internal func scheduleStaleCleanup() {
        staleCleanupTask?.cancel()
        staleCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.cleanupStaleTaps()
        }
    }
}
