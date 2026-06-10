// SoundTune/Audio/Permission/BluetoothPermission.swift
import Foundation
import CoreBluetooth
import AppKit
import os

private let logger = Logger(subsystem: "com.soundtune.SoundTune", category: "BluetoothPermission")

// MARK: - Permission Status

enum BluetoothPermissionStatus: Sendable {
    case unknown
    case authorized
    case denied
}

// MARK: - BluetoothPermission

@Observable
@MainActor
final class BluetoothPermission: NSObject, CBCentralManagerDelegate {

    private(set) var status: BluetoothPermissionStatus = .unknown
    var onPermissionRequestStarted: (() -> Void)?
    var onPermissionGranted: (() -> Void)?

    private var centralManager: CBCentralManager?
    private var permissionWatchTask: Task<Void, Never>?
    private var isWaitingForPermission = false

    override init() {
        super.init()
        refreshStatus()
        registerForActivation()
    }

    /// Check current Bluetooth authorization status.
    func refreshStatus() {
        let auth = CBCentralManager.authorization
        let newStatus: BluetoothPermissionStatus
        switch auth {
        case .allowedAlways:
            newStatus = .authorized
        case .denied, .restricted:
            newStatus = .denied
        case .notDetermined:
            newStatus = .unknown
        @unknown default:
            newStatus = .unknown
        }
        updateStatus(newStatus)
        logger.debug("Bluetooth permission status: \(String(describing: self.status))")
    }

    /// Trigger the system permission dialog.
    func request() {
        guard status != .authorized else { return }
        beginPermissionWait()
        onPermissionRequestStarted?()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.status == .denied {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                self.centralManager = CBCentralManager(delegate: self, queue: nil, options: [
                    CBCentralManagerOptionShowPowerAlertKey: false
                ])
            }
        }
    }

    private func updateStatus(_ newStatus: BluetoothPermissionStatus) {
        status = newStatus
        if newStatus == .authorized, isWaitingForPermission {
            isWaitingForPermission = false
            permissionWatchTask?.cancel()
            permissionWatchTask = nil
            onPermissionGranted?()
        }
    }

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

    // MARK: - CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.refreshStatus()
        }
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
}
