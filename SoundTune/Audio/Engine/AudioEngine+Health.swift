// SoundTune/Audio/Engine/AudioEngine+Health.swift
import AudioToolbox
import Foundation
import os

@MainActor
extension AudioEngine {
    // MARK: - Tap Health Monitor

    /// Starts a periodic health check that recreates unresponsive taps.
    /// Checks every 2 seconds; after 3 consecutive misses (~6s), the tap is presumed dead.
    internal func startHealthMonitor() {
        guard healthMonitorTask == nil else { return }
        healthMonitorTask = Task { @MainActor [weak self] in
            var consecutiveMisses: [pid_t: Int] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }

                // Skip entirely when no taps exist — avoids unnecessary work at idle (#176)
                guard !self.taps.isEmpty else { continue }

                let now = Date()

                for (pid, tap) in self.taps {
                    // Skip muted apps — no callbacks while muted isn't a health signal
                    guard !tap.isMuted else { continue }

                    // Skip PIDs in recovery cooldown to prevent recreation thrashing
                    if let cooldownEnd = self.tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                        continue
                    }

                    guard tap.isHealthCheckEligible(minActiveSeconds: 5.0) else { continue }

                    // Only health-check apps that are actively streaming (isRunning=true).
                    // Paused apps have no callbacks, which is normal — not a health signal.
                    let isActivelyStreaming = self.processMonitor.activeApps.contains { $0.id == pid }
                    guard isActivelyStreaming else {
                        consecutiveMisses[pid] = 0
                        continue
                    }

                    if tap.hasRecentAudioCallback(within: 3.0) {
                        consecutiveMisses[pid] = 0
                    } else {
                        let misses = (consecutiveMisses[pid] ?? 0) + 1
                        consecutiveMisses[pid] = misses

                        if misses >= 3 {
                            self.logger.warning("Tap for PID \(pid) unresponsive (\(misses) misses), recreating")
                            consecutiveMisses[pid] = 0
                            await self.recreateTap(for: pid)
                        }
                    }
                }

                // Prune entries for PIDs no longer tracked
                consecutiveMisses = consecutiveMisses.filter { self.taps[$0.key] != nil }
                self.tapRecoveryCooldownUntil = self.tapRecoveryCooldownUntil.filter { self.taps[$0.key] != nil }
            }
        }
    }

    internal func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    /// Tears down and recreates a tap for a given PID, preserving routing and settings.
    /// Async: awaits full CoreAudio resource teardown before creating the replacement tap
    /// to prevent orphaned IO procs from accumulating (issue #176).
    private func recreateTap(for pid: pid_t) async {
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        let deviceUIDs = oldTap.currentDeviceUIDs
        await oldTap.invalidateAsync()

        // Set cooldown to prevent thrashing
        tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(20)

        // Find the current AudioApp entry for this PID
        guard let app = apps.first(where: { $0.id == pid }) else {
            logger.debug("No active app for PID \(pid), skipping tap recreation")
            appliedPIDs.remove(pid)
            return
        }

        // Allow re-initialization
        appliedPIDs.remove(pid)

        // Re-route to the same device(s), preserving multi-device routing
        if deviceUIDs.count > 1 {
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
            if taps[app.id] != nil {
                appDeviceRouting[app.id] = deviceUIDs[0]
            }
        } else if let deviceUID = deviceUIDs.first {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }

        // Mark as applied to avoid redundant re-processing in applyPersistedSettings
        if taps[pid] != nil {
            appliedPIDs.insert(pid)
        }

        // Restore mute state
        if let muted = volumeState.loadSavedMute(for: pid, identifier: app.persistenceIdentifier), muted {
            taps[pid]?.isMuted = true
        }
    }

    /// Recreates the aggregate at the device's new rate for every tap on a BT output that changed
    /// sample rate (A2DP↔SCO), so each tap's IOProc re-rates to match. Falls back to a full tap
    /// recreate if the in-controller recreation throws.
    internal func handleBTDeviceSampleRateChanged(uid: String, newRate: Double) async {
        logger.info("[RATE] BT output \(uid, privacy: .public) → \(newRate, format: .fixed(precision: 0)) Hz — recreating affected taps (clean dip)")
        let affected = taps.filter { $0.value.currentDeviceUIDs.contains(uid) }
        for (pid, tap) in affected {
            do {
                logger.info("[RATE] Recreating tap for PID \(pid)")
                try await tap.recreateForOutputRateChange()
            } catch {
                logger.error("[RATE] Recreate failed for PID \(pid): \(error.localizedDescription) — falling back to full recreate")
                await recreateTap(for: pid)
            }
        }
    }
}
