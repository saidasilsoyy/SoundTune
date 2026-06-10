// SoundTune/Audio/Keys/AccessibilityPermissionService.swift
import AppKit
import ApplicationServices
import os

@MainActor
protocol AccessibilityTrustProviding: AnyObject {
    /// Authoritative, non-cached read.
    var isTrusted: Bool { get }
    /// Syncs cached state against the authoritative read.
    func refresh()
}

/// Tracks AX trust via `AXIsProcessTrusted()` plus the
/// `com.apple.accessibility.api` distributed notification (250ms debounce).
@Observable
@MainActor
final class AccessibilityPermissionService: AccessibilityTrustProviding {
    private(set) var isTrustedCached: Bool

    /// Invoked on the main actor whenever `isTrustedCached` flips. Global path —
    /// `.onChange` in a view is insufficient because the popup may not be mounted.
    var onTrustChanged: ((Bool) -> Void)?
    var onPermissionRequestStarted: (() -> Void)?
    var onPermissionGranted: (() -> Void)?

    private var trustObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var permissionWatchTask: Task<Void, Never>?
    private var isWaitingForPermission = false

    private let logger = Logger(subsystem: "com.soundtune.SoundTune", category: "AccessibilityPermissionService")

    var refreshDidFinish: (() -> Void)?

    init() {
        self.isTrustedCached = AXIsProcessTrusted()
        registerForActivation()
    }

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func refresh() {
        let current = AXIsProcessTrusted()
        guard current != isTrustedCached else {
            refreshDidFinish?()
            return
        }
        isTrustedCached = current
        logger.info("Accessibility trust refreshed synchronously: \(current ? "granted" : "revoked")")
        onTrustChanged?(current)
        if current, isWaitingForPermission {
            finishPermissionWait()
        }
        refreshDidFinish?()
    }

    /// Idempotent. Subscribes to `com.apple.accessibility.api`.
    func start() {
        guard trustObserver == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleDebouncedRefresh()
            }
        }
    }

    /// Idempotent.
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        permissionWatchTask?.cancel()
        permissionWatchTask = nil
        if let observer = trustObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            trustObserver = nil
        }
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.refresh()
            self.debounceTask = nil
        }
    }

    /// Prompts for AX access and registers the app in the Accessibility pane list
    /// as a side effect — the only supported pre-population path.
    @discardableResult
    func promptForTrust() -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt; the framework symbol is a
        // non-concurrency-safe global var in Swift 6 and the constant has been
        // "AXTrustedCheckOptionPrompt" since macOS 10.9.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Registers SoundTune in the Accessibility list and lets macOS present
    /// its native prompt. Opening System Settings here as well would put the
    /// settings window behind that prompt and create a duplicate flow.
    func requestAccess() {
        guard !isTrustedCached else { return }
        beginPermissionWait()
        onPermissionRequestStarted?()
        DispatchQueue.main.async { [weak self] in
            _ = self?.promptForTrust()
        }
    }

    private func beginPermissionWait() {
        isWaitingForPermission = true
        permissionWatchTask?.cancel()
        permissionWatchTask = Task { @MainActor [weak self] in
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
                if !self.isWaitingForPermission { return }
            }
            self?.isWaitingForPermission = false
            self?.permissionWatchTask = nil
        }
    }

    private func finishPermissionWait() {
        isWaitingForPermission = false
        permissionWatchTask?.cancel()
        permissionWatchTask = nil
        onPermissionGranted?()
    }

    private func registerForActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }
}
