// SoundTune/Audio/Permission/AudioRecordingPermission.swift
import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.soundtune.SoundTune", category: "Permission")

// MARK: - Permission Status

enum AudioCapturePermissionStatus {
    case unknown
    case authorized
    case denied
}

// MARK: - AudioRecordingPermission

@Observable
@MainActor
final class AudioRecordingPermission {

    private(set) var status: AudioCapturePermissionStatus = .unknown
    var onPermissionRequestStarted: (() -> Void)?
    var onPermissionGranted: (() -> Void)?

    private var permissionWatchTask: Task<Void, Never>?
    private var isWaitingForPermission = false

    init() {
        refreshStatus()
        registerForActivation()
    }

    /// Check current TCC status without prompting.
    func refreshStatus() {
        #if ENABLE_TCC_SPI
        let result = Self.preflight()
        let newStatus: AudioCapturePermissionStatus
        switch result {
        case 0:
            newStatus = .authorized
        case 1:
            newStatus = .denied
        default:
            newStatus = .unknown
        }
        updateStatus(newStatus)
        logger.debug("Audio capture permission preflight: \(result) → \(String(describing: self.status))")
        #else
        updateStatus(.authorized)
        #endif
    }

    /// Trigger the system permission dialog. Only shows once per app per TCC service.
    /// Subsequent calls are no-ops at the OS level.
    func request() {
        #if ENABLE_TCC_SPI
        guard status != .authorized else { return }
        beginPermissionWait()
        onPermissionRequestStarted?()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.status == .denied {
                self.openSystemSettings()
            } else {
                Self.requestAccess { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        self.updateStatus(granted ? .authorized : .denied)
                        logger.info("Audio capture permission request result: \(granted)")
                    }
                }
            }
        }
        #endif
    }

    private func updateStatus(_ newStatus: AudioCapturePermissionStatus) {
        status = newStatus
        if newStatus == .authorized, isWaitingForPermission {
            isWaitingForPermission = false
            permissionWatchTask?.cancel()
            permissionWatchTask = nil
            onPermissionGranted?()
        }
    }

    #if DEBUG
    func testingOverrideStatus(_ newStatus: AudioCapturePermissionStatus) {
        updateStatus(newStatus)
    }
    #endif

    private func beginPermissionWait() {
        isWaitingForPermission = true
        permissionWatchTask?.cancel()
        permissionWatchTask = Task { @MainActor [weak self] in
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.refreshStatus()
                if !self.isWaitingForPermission { return }
            }
            self?.isWaitingForPermission = false
            self?.permissionWatchTask = nil
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - App Activation Observer

    private func registerForActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatus()
            }
        }
    }

    // MARK: - TCC SPI (Private Framework)

    #if ENABLE_TCC_SPI
    private static let tccServiceAudioCapture = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let preflightSPI: PreflightFunc? = {
        guard let handle = apiHandle,
              let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFunc.self)
    }()

    private static let requestSPI: RequestFunc? = {
        guard let handle = apiHandle,
              let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFunc.self)
    }()

    /// Returns: 0 = authorized, 1 = denied, -1 = SPI unavailable
    private static func preflight() -> Int {
        guard let spi = preflightSPI else {
            logger.warning("TCC preflight SPI unavailable")
            return -1
        }
        return spi(tccServiceAudioCapture, nil)
    }

    private static func requestAccess(completion: @escaping (Bool) -> Void) {
        guard let spi = requestSPI else {
            logger.warning("TCC request SPI unavailable")
            completion(false)
            return
        }
        spi(tccServiceAudioCapture, nil, completion)
    }
    #endif
}
