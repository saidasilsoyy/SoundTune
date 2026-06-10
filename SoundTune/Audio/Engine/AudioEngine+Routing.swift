// SoundTune/Audio/Engine/AudioEngine+Routing.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@MainActor
extension AudioEngine {
    /// Sets the system default output device, routes followsDefault apps, and registers
    /// an echo so the resulting CoreAudio callback is consumed rather than treated as
    /// an external change.
    /// UI code should call this instead of `deviceVolumeMonitor.setDefaultDevice` directly.
    @discardableResult
    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceVolumeMonitor.setDefaultDevice(deviceID) else { return false }
        if let uid = deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid {
            outputEchoTracker.increment(uid)
            lastConfirmedDefaultUID = uid
            routeFollowsDefaultApps(to: uid)
        }
        return true
    }

    /// Sets the output device for an app.
    /// - Parameters:
    ///   - app: The app to route
    ///   - deviceUID: The device UID to route to, or nil to follow system default
    func setDevice(for app: AudioApp, deviceUID: String?) {
        if let deviceUID = deviceUID {
            // Explicit device selection - stop following default
            followsDefault.remove(app.id)
            // Defensive: re-persist routing even if in-memory state matches,
            // to guard against settings file corruption or incomplete prior writes
            settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)

            // If transitioning from follows-default to explicit and tap has a stream-specific
            // source, refresh to mixdown so it won't go stale when the default changes later.
            if let tap = taps[app.id], tap.tapSourceDeviceUID != nil {
                Task {
                    do {
                        try await tap.refreshTapSource(nil)
                        self.applyTapOutputState(to: tap, for: app.id)
                    } catch {
                        self.logger.error("Failed to refresh tap source for \(app.name): \(error)")
                    }
                }
            }

            guard appDeviceRouting[app.id] != deviceUID else { return }
            appDeviceRouting[app.id] = deviceUID
        } else {
            // "System Audio" selected - follow default
            followsDefault.insert(app.id)
            settingsManager.setFollowDefault(for: app.persistenceIdentifier)

            // Route to current default (if available)
            guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                // No default available yet - routing will happen when default becomes available
                // via handleDefaultDeviceChanged callback
                logger.warning("No default device available for \(app.name), will route when available")
                return
            }
            guard appDeviceRouting[app.id] != defaultUID else { return }
            appDeviceRouting[app.id] = defaultUID
        }

        // Switch tap if needed
        guard let targetUID = appDeviceRouting[app.id] else { return }
        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: followsDefault.contains(app.id))
        if let tap = taps[app.id] {
            Task {
                do {
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyDeviceEQToTap(tap)
                    self.applyAutoEQToTap(tap)
                    self.logger.debug("Switched \(app.name) to device: \(targetUID)")
                } catch {
                    self.logger.error("Failed to switch device for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            ensureTapExists(for: app, deviceUID: targetUID)
        }
    }

    func getDeviceUID(for app: AudioApp) -> String? {
        appDeviceRouting[app.id]
    }

    /// Returns true if the app follows system default device
    func isFollowingDefault(for app: AudioApp) -> Bool {
        followsDefault.contains(app.id)
    }

    // MARK: - Multi-Device Selection

    /// Gets the device selection mode for an app
    func getDeviceSelectionMode(for app: AudioApp) -> DeviceSelectionMode {
        volumeState.getDeviceSelectionMode(for: app.id)
    }

    /// Sets the device selection mode for an app.
    /// Triggers tap reconfiguration when mode changes.
    func setDeviceSelectionMode(for app: AudioApp, to mode: DeviceSelectionMode) {
        let previousMode = volumeState.getDeviceSelectionMode(for: app.id)
        volumeState.setDeviceSelectionMode(for: app.id, to: mode, identifier: app.persistenceIdentifier)

        guard previousMode != mode else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Gets the selected device UIDs for multi-mode
    func getSelectedDeviceUIDs(for app: AudioApp) -> Set<String> {
        volumeState.getSelectedDeviceUIDs(for: app.id)
    }

    /// Sets the selected device UIDs for multi-mode.
    /// Triggers tap reconfiguration when in multi mode.
    func setSelectedDeviceUIDs(for app: AudioApp, to uids: Set<String>) {
        let previousUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
        volumeState.setSelectedDeviceUIDs(for: app.id, to: uids, identifier: app.persistenceIdentifier)

        guard previousUIDs != uids,
              getDeviceSelectionMode(for: app) == .multi else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Updates tap configuration based on current mode and selected devices
    internal func updateTapForCurrentMode(for app: AudioApp) async {
        let mode = getDeviceSelectionMode(for: app)

        let deviceUIDs: [String]
        switch mode {
        case .single:
            if isFollowingDefault(for: app), let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else if let deviceUID = appDeviceRouting[app.id] {
                deviceUIDs = [deviceUID]
            } else if let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else {
                logger.warning("No device available for \(app.name) in single mode")
                return
            }

        case .multi:
            let selectedUIDs = getSelectedDeviceUIDs(for: app).sorted()
            if selectedUIDs.isEmpty {
                return
            }
            deviceUIDs = selectedUIDs
        }

        // Update or create tap with the device set
        if let tap = taps[app.id] {
            // Tap exists - update devices
            if tap.currentDeviceUIDs != deviceUIDs {
                do {
                    let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
                    try await tap.updateDevices(to: deviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)
                    applyDeviceEQToTap(tap)
                    applyAutoEQToTap(tap)
                    logger.debug("Updated \(app.name) to \(deviceUIDs.count) device(s)")
                } catch {
                    logger.error("Failed to update devices for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            // No tap exists - create one
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
        }
    }

    /// Creates a tap with the specified device UIDs
    internal func ensureTapWithDevices(for app: AudioApp, deviceUIDs: [String]) {
        guard !deviceUIDs.isEmpty else { return }
        guard taps[app.id] == nil else { return }
        guard permission.status == .authorized else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, deviceUIDs, preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUIDs[0],
                deviceVolume: tap.currentDeviceVolume
            )
            try tap.activate(initial: initial)
            taps[app.id] = tap

            // Catalog AutoEQ may not have been cached yet — kick off async resolve.
            if initial.autoEQProfile == nil {
                applyAutoEQToTap(tap)
            }

            logger.debug("Created tap for \(app.name) on \(deviceUIDs.count) device(s)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    func applyPersistedSettings() {
        guard permission.status == .authorized else { return }

        // Warm the AutoEQ cache for every (app, device) selection so that subsequent
        // tap activations can apply correction synchronously inside activate(initial:)
        // instead of falling back to the async resolve path. Imported profiles are
        // already loaded by AutoEQProfileManager.init.
        let selectedProfileIDs: Set<String> = Set(apps.compactMap { app -> String? in
            let deviceUID = appDeviceRouting[app.id] ?? deviceVolumeMonitor.defaultDeviceUID
            guard let deviceUID, let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
            return selection.isEnabled ? selection.profileID : nil
        })
        let manager = autoEQProfileManager
        Task { @MainActor in
            for id in selectedProfileIDs where manager.profile(for: id) == nil {
                _ = await manager.resolveProfile(for: id)
            }
        }

        for app in apps {
            guard !appliedPIDs.contains(app.id) else { continue }
            guard !settingsManager.isIgnored(app.persistenceIdentifier) else { continue }

            // Load saved device selection mode (single vs multi)
            let savedMode = volumeState.loadSavedDeviceSelectionMode(for: app.id, identifier: app.persistenceIdentifier)
            let mode = savedMode ?? .single

            // Load saved volume, mute, and boost state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)
            _ = volumeState.loadSavedBoost(for: app.id, identifier: app.persistenceIdentifier)

            // Handle multi-device mode
            if mode == .multi {
                if let savedUIDs = volumeState.loadSavedSelectedDeviceUIDs(for: app.id, identifier: app.persistenceIdentifier),
                   !savedUIDs.isEmpty {
                    // Filter to currently available devices, maintaining deterministic order
                    let availableUIDs = savedUIDs.filter { deviceMonitor.device(for: $0) != nil }
                        .sorted()  // Deterministic ordering
                    if !availableUIDs.isEmpty {
                        logger.debug("Restoring multi-device mode for \(app.name) with \(availableUIDs.count) device(s)")
                        ensureTapWithDevices(for: app, deviceUIDs: availableUIDs)

                        // Mark as applied if tap created successfully
                        guard taps[app.id] != nil else { continue }
                        // Set primary device routing so the UI row renders
                        appDeviceRouting[app.id] = availableUIDs[0]
                        appliedPIDs.insert(app.id)

                        // Apply volume (with boost) and mute
                        if savedVolume != nil {
                            if let tap = taps[app.id] {
                                applyTapOutputState(to: tap, for: app.id, deviceUIDs: availableUIDs)
                            }
                        }
                        if let muted = savedMute, muted {
                            taps[app.id]?.isMuted = true
                        }
                        continue  // Skip single-device path
                    }
                    // All saved devices unavailable - fall through to single-device mode
                    logger.debug("All multi-mode devices unavailable for \(app.name), falling back to single mode")
                }
            }

            // Single-device mode (or multi-mode fallback)
            let deviceUID: String
            if settingsManager.isFollowingDefault(for: app.persistenceIdentifier) {
                // App follows system default (new app or explicitly set to follow)
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device available for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) follows system default: \(deviceUID)")
            } else if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
                      deviceMonitor.device(for: savedDeviceUID) != nil {
                // Explicit device routing exists and device is available
                deviceUID = savedDeviceUID
                logger.debug("Applying saved device routing to \(app.name): \(deviceUID)")
            } else {
                // Saved device temporarily unavailable: fall back to system default for now
                // Don't persist - keep original device preference for when it reconnects
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) device temporarily unavailable, using default: \(deviceUID)")
            }
            appDeviceRouting[app.id] = deviceUID

            // If a tap already exists but is on the wrong device (e.g., app reappeared
            // after the default changed while it was absent), switch it.
            if let existingTap = taps[app.id], existingTap.currentDeviceUIDs != [deviceUID] {
                let preferredSource = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
                Task {
                    do {
                        try await existingTap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredSource)
                        self.applyTapOutputState(to: existingTap, for: app.id, deviceUIDs: [deviceUID])
                        self.applyDeviceEQToTap(existingTap)
                        self.applyAutoEQToTap(existingTap)
                    } catch {
                        self.logger.error("Failed to re-route \(app.name) to \(deviceUID): \(error.localizedDescription)")
                    }
                }
                appliedPIDs.insert(app.id)
                continue
            }

            // Always create tap for audio apps (always-on strategy)
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Only mark as applied if tap was successfully created
            // This allows retry on next applyPersistedSettings() call if tap failed
            guard taps[app.id] != nil else { continue }
            appliedPIDs.insert(app.id)

            if savedVolume != nil {
                let effective = effectiveVolume(for: app.id, deviceUIDs: [deviceUID])
                let displayPercent = Int(effective * 100)
                logger.debug("Applying saved volume \(displayPercent)% (with boost) to \(app.name)")
                taps[app.id]?.volume = effective
            }

            if let muted = savedMute, muted {
                logger.debug("Applying saved mute state to \(app.name)")
                taps[app.id]?.isMuted = true
            }
        }
    }

    internal func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard taps[app.id] == nil else { return }
        guard permission.status == .authorized else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, [deviceUID], preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: [deviceUID])

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUID,
                deviceVolume: tap.currentDeviceVolume
            )
            try tap.activate(initial: initial)
            taps[app.id] = tap

            // Catalog AutoEQ may not have been cached yet — kick off async resolve.
            // Imported profiles always hit the synchronous path above.
            if initial.autoEQProfile == nil {
                applyAutoEQToTap(tap)
            }

            logger.debug("Created tap for \(app.name)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Restores the default to `lastConfirmedDefaultUID` (what the user/SoundTune intended).
    /// Falls back to highest-priority device if the confirmed device is gone.
    internal func restoreConfirmedDefault() {
        if let restoreUID = lastConfirmedDefaultUID,
           let device = deviceMonitor.device(for: restoreUID),
           isAliveCheck(device.id) {
            if deviceVolumeMonitor.defaultDeviceUID != restoreUID {
                if deviceVolumeMonitor.setDefaultDevice(device.id) {
                    outputEchoTracker.increment(restoreUID)
                    logger.info("Restored default → \(device.name)")
                }
            }
            routeFollowsDefaultApps(to: restoreUID)
        } else {
            reEvaluateOutputDefault()
        }
    }

    /// Ensures system default matches highest-priority alive connected device.
    /// Routes followsDefault apps and switches their taps if default changes.
    /// Returns the resolved target UID.
    @discardableResult
    internal func reEvaluateOutputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        if target.uid != currentDefault {
            if deviceVolumeMonitor.setDefaultDevice(target.id) {
                outputEchoTracker.increment(target.uid)
                logger.info("System default → \(target.name)")
            }
        }

        lastConfirmedDefaultUID = target.uid
        routeFollowsDefaultApps(to: target.uid)
        return target.uid
    }

    /// Ensures system default input matches highest-priority alive connected input device.
    /// Returns the resolved target UID.
    @discardableResult
    internal func reEvaluateInputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        if target.uid != deviceVolumeMonitor.defaultInputDeviceUID {
            if deviceVolumeMonitor.setDefaultInputDevice(target.id) {
                inputEchoTracker.increment(target.uid)
                logger.info("Default input → \(target.name)")
            }
        }
        return target.uid
    }

    /// Routes all followsDefault apps to the given device UID and switches their taps.
    /// Early-exits if all apps are already routed to the target (avoids unnecessary tap switches).
    internal func routeFollowsDefaultApps(to targetUID: String) {
        guard !followsDefault.allSatisfy({ appDeviceRouting[$0] == targetUID }) else { return }

        for pid in followsDefault {
            appDeviceRouting[pid] = targetUID
        }

        var tapsToSwitch: [(app: AudioApp, tap: any ProcessTapControlling)] = []
        for app in apps {
            guard followsDefault.contains(app.id), let tap = taps[app.id] else { continue }
            tapsToSwitch.append((app, tap))
        }
        guard !tapsToSwitch.isEmpty else { return }

        Task {
            for (app, tap) in tapsToSwitch {
                do {
                    let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: true)
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyDeviceEQToTap(tap)
                    self.applyAutoEQToTap(tap)
                } catch {
                    self.logger.error("Failed to switch \(app.name) to \(targetUID): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Called when device disappears - updates routing and switches taps immediately
    internal func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        // Clean up alive watcher — use UID lookup since device is already removed from monitor
        removeAliveWatcher(forUID: deviceUID)

        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = outputPriorityState, uid == deviceUID {
            task.cancel()
            outputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultOutput = deviceUID == deviceVolumeMonitor.defaultDeviceUID

        // Use priority-based fallback (resolve checks isDeviceAlive internally)
        let fallbackDevice = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        var affectedApps: [AudioApp] = []
        var singleModeTapsToSwitch: [(tap: any ProcessTapControlling, fallbackUID: String)] = []
        var multiModeTapsToUpdate: [(tap: any ProcessTapControlling, remainingUIDs: [String])] = []

        // Iterate over taps instead of apps - apps list may be empty if disconnected device
        // was the system default (CoreAudio removes app from process list when output disappears)
        for tap in taps.values {
            let app = tap.app
            let mode = getDeviceSelectionMode(for: app)

            // Check if this tap uses the disconnected device
            guard tap.currentDeviceUIDs.contains(deviceUID) else { continue }

            affectedApps.append(app)

            if mode == .multi && tap.currentDeviceUIDs.count > 1 {
                // Multi-device mode: remove disconnected device, keep others
                let remainingUIDs = tap.currentDeviceUIDs.filter { $0 != deviceUID }.sorted()
                if !remainingUIDs.isEmpty {
                    multiModeTapsToUpdate.append((tap: tap, remainingUIDs: remainingUIDs))
                    // Update in-memory selection to remove disconnected device (don't persist)
                    var currentSelection = volumeState.getSelectedDeviceUIDs(for: app.id)
                    currentSelection.remove(deviceUID)
                    volumeState.setSelectedDeviceUIDs(for: app.id, to: currentSelection, identifier: nil)
                    continue
                }
                // All devices gone in multi-mode, fall through to single-device fallback
            }

            // Single-device mode (or multi-mode with no remaining devices): switch to fallback
            if let fallback = fallbackDevice {
                appDeviceRouting[app.id] = fallback.uid
                // Set to follow default in-memory (UI shows "System Audio")
                // Don't persist - original device preference stays in settings for reconnection
                followsDefault.insert(app.id)
                singleModeTapsToSwitch.append((tap: tap, fallbackUID: fallback.uid))
            } else {
                logger.error("No fallback device available for \(app.name)")
            }
        }

        // Execute device switches
        if !singleModeTapsToSwitch.isEmpty || !multiModeTapsToUpdate.isEmpty {
            Task {
                // Handle single-mode switches — source device is dead, skip crossfade
                for (tap, fallbackUID) in singleModeTapsToSwitch {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [fallbackUID], isFollowsDefault: true)
                        try await tap.switchDevice(to: fallbackUID, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: true)
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [fallbackUID])
                        self.applyDeviceEQToTap(tap)
                        self.applyAutoEQToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) to fallback: \(error.localizedDescription)")
                    }
                }

                // Handle multi-mode updates (remove disconnected device from aggregate)
                // Source device is dead, skip crossfade
                for (tap, remainingUIDs) in multiModeTapsToUpdate {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: remainingUIDs, isFollowsDefault: self.followsDefault.contains(tap.app.id))
                        try await tap.updateDevices(to: remainingUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID, sourceDeviceDead: true)
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: remainingUIDs)
                        self.applyDeviceEQToTap(tap)
                        self.applyAutoEQToTap(tap)
                        self.logger.debug("Removed \(deviceName) from \(tap.app.name) multi-device output")
                    } catch {
                        self.logger.error("Failed to update \(tap.app.name) devices: \(error.localizedDescription)")
                    }
                }
            }
        }

        if !affectedApps.isEmpty {
            let fallbackName = fallbackDevice?.name ?? "none"
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) affected")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showDisconnectNotification(deviceName: deviceName, fallbackName: fallbackName, affectedApps: affectedApps)
            }
        }

        onDeviceDisconnectedHUD?(deviceName)

        // If the disconnected device was the system default, override to priority fallback
        if wasDefaultOutput {
            reEvaluateOutputDefault(excluding: deviceUID)
        }
    }

    /// Called when a device appears - switches pinned apps back to their preferred device
    internal func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        // Register newly connected device in priority list
        settingsManager.ensureDeviceInPriority(deviceUID)

        var affectedApps: [AudioApp] = []
        var tapsToSwitch: [any ProcessTapControlling] = []

        // Iterate over taps for consistency with handleDeviceDisconnected
        for tap in taps.values {
            let app = tap.app

            // Skip apps that are PERSISTED as following default - they don't have explicit device preferences
            // Note: in-memory followsDefault may include temporarily displaced apps, so check persisted state
            guard !settingsManager.isFollowingDefault(for: app.persistenceIdentifier) else { continue }

            // Check if this app was pinned to the reconnected device (from persisted settings)
            let persistedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier)
            guard persistedUID == deviceUID else { continue }

            // App was pinned to this device - switch it back
            guard appDeviceRouting[app.id] != deviceUID else { continue }

            affectedApps.append(app)
            appDeviceRouting[app.id] = deviceUID
            // Remove from followsDefault since we're restoring explicit routing
            followsDefault.remove(app.id)
            tapsToSwitch.append(tap)
        }

        if !tapsToSwitch.isEmpty {
            Task {
                for tap in tapsToSwitch {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: false)
                        try await tap.switchDevice(to: deviceUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [deviceUID])
                        self.applyDeviceEQToTap(tap)
                        self.applyAutoEQToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) back to \(deviceName): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Second pass: restore multi-device apps that had this device in their selection
        var multiModeTapsToUpdate: [any ProcessTapControlling] = []
        for tap in taps.values {
            let app = tap.app
            guard settingsManager.getDeviceSelectionMode(for: app.persistenceIdentifier) == .multi else { continue }
            guard let persistedUIDs = settingsManager.getSelectedDeviceUIDs(for: app.persistenceIdentifier),
                  persistedUIDs.contains(deviceUID) else { continue }
            let currentUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
            guard !currentUIDs.contains(deviceUID) else { continue }

            // Add the reconnected device back to in-memory selection
            var updatedUIDs = currentUIDs
            updatedUIDs.insert(deviceUID)
            volumeState.setSelectedDeviceUIDs(for: app.id, to: updatedUIDs, identifier: app.persistenceIdentifier)
            multiModeTapsToUpdate.append(tap)
        }

        if !multiModeTapsToUpdate.isEmpty {
            Task {
                for tap in multiModeTapsToUpdate {
                    await self.updateTapForCurrentMode(for: tap.app)
                }
            }
            logger.info("\(deviceName) reconnected, restored to \(multiModeTapsToUpdate.count) multi-device app(s)")
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) reconnected, switched \(affectedApps.count) app(s) back")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showReconnectNotification(deviceName: deviceName, affectedApps: affectedApps)
            }
        }

        // Only override the default if the newly connected device IS the highest-priority
        // device (i.e., a higher-priority device just came back). If a lower-priority device
        // connects while the user is on a higher-priority device, respect the current default —
        // the user chose it. We still enter PENDING_AUTOSWITCH to guard against macOS
        // auto-switching to the new device.
        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        let isNewDeviceHigherPriority = (deviceUID == Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            isAlive: isAliveCheck
        )?.uid)

        // If this device is present but not alive, watch for it to become alive
        if let device = deviceMonitor.device(for: deviceUID),
           !isAliveCheck(device.id) {
            installAliveWatcher(deviceID: device.id, uid: deviceUID, name: deviceName)
        }

        if isNewDeviceHigherPriority, deviceUID != currentDefault {
            // A higher-priority device reconnected — switch to it
            reEvaluateOutputDefault()
        } else if !isNewDeviceHigherPriority, currentDefault == deviceUID {
            // macOS already auto-switched to the lower-priority device — restore
            // what the user was on (not highest priority — they may have chosen a mid-priority device)
            restoreConfirmedDefault()
        }

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one.
        if case .pendingAutoSwitch(_, let oldTask) = outputPriorityState {
            oldTask.cancel()
            outputPriorityState = .stable
        }

        // Always enter PENDING_AUTOSWITCH for the newly connected device.
        // macOS may auto-switch to it multiple times during BT firmware handshake.
        // Without this grace period, auto-switches would be treated as "genuine user change".
        let transport = deviceMonitor.device(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.outputPriorityState = .stable
            self.logger.debug("Auto-switch grace period expired, no macOS switch detected")
        }

        lastAutoSwitchOverrideTime = nil
        outputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
        logger.debug("Entered PENDING_AUTOSWITCH for \(deviceName) (\(timeout)s grace)")

        onDeviceConnectedHUD?(deviceName)
    }
}
