// SoundTune/Audio/Monitors/BluetoothDeviceMonitor.swift
import AppKit
import IOBluetooth
import os

@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
private func IOBluetoothPreferenceSetControllerPowerState(_ powerState: Int32) -> Int32

/// Discovers paired-but-disconnected Bluetooth audio devices and initiates connections.
/// All IOBluetooth interaction is isolated here — no other file imports IOBluetooth.
///
/// All IOBluetooth calls are dispatched to a dedicated serial queue (`btQueue`) to
/// serialize Mach port IPC and avoid the cooperative thread pool used by Task.detached.
@Observable
@MainActor
final class BluetoothDeviceMonitor {

    // MARK: - Published State

    /// Whether the Bluetooth hardware is powered on.
    var isBluetoothOn: Bool = false

    /// Paired Bluetooth devices (all devices), sorted by name.
    private(set) var pairedDevices: [PairedBluetoothDevice] = []

    /// Paired audio BT devices (only A2DP/HFP profiles), sorted by name.
    private(set) var pairedAudioDevices: [PairedBluetoothDevice] = []

    /// MAC addresses currently in-flight (spinner shown).
    private(set) var connectingIDs: Set<String> = []

    /// MAC addresses currently disconnecting.
    private(set) var disconnectingIDs: Set<String> = []

    /// Inline error messages keyed by MAC address.
    private(set) var connectionErrors: [String: String] = [:]

    /// Parsed battery levels keyed by Bluetooth device name.
    private(set) var deviceBatteryLevels: [String: BluetoothBatteryStatus] = [:]

    // MARK: - Private

    private let logger = Logger(
        subsystem: "com.soundtune.SoundTune",
        category: "BluetoothDeviceMonitor"
    )

    /// Dedicated serial queue for all IOBluetooth IPC.
    /// Serializes calls to avoid concurrent Mach port access and provides a stable
    /// thread context (unlike Task.detached which uses the cooperative thread pool).
    private nonisolated static let btQueue = DispatchQueue(label: "com.soundtune.bluetooth")

    /// Pending timeout tasks keyed by MAC address.
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Pending connection tasks keyed by MAC address.
    private var connectionTasks: [String: Task<Void, Never>] = [:]

    /// Error auto-clear tasks keyed by MAC address.
    private var errorClearTasks: [String: Task<Void, Never>] = [:]

    /// In-flight refresh task — cancelled on each new refresh to avoid stacking.
    private var refreshTask: Task<Void, Never>?

    /// In-flight battery fetch task — cancelled on new refreshes to avoid stacking.
    private var batteryFetchTask: Task<Void, Never>?

    /// In-flight battery polling task when a device connects.
    private var batteryPollingTask: Task<Void, Never>?

    private let connectTimeoutSeconds: Double = 12

    // MARK: - A2DP / HFP SDP UUIDs

    private nonisolated(unsafe) static let a2dpSinkUUID = IOBluetoothSDPUUID(uuid16: 0x110B)!
    private nonisolated(unsafe) static let hfpUUID = IOBluetoothSDPUUID(uuid16: 0x111E)!

    // Read from the nonisolated deinit to call removeObserver.
    @ObservationIgnored private nonisolated(unsafe) var powerOnObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var powerOffObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    deinit {
        if let powerOnObserver { NotificationCenter.default.removeObserver(powerOnObserver) }
        if let powerOffObserver { NotificationCenter.default.removeObserver(powerOffObserver) }
    }

    func start() {
        guard powerOnObserver == nil, powerOffObserver == nil else {
            refresh()
            return
        }

        powerOnObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("IOBluetoothHostControllerPoweredOnNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }

        powerOffObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("IOBluetoothHostControllerPoweredOffNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }

        refresh()
    }

    func stop() {
        if let powerOnObserver {
            NotificationCenter.default.removeObserver(powerOnObserver)
            self.powerOnObserver = nil
        }
        if let powerOffObserver {
            NotificationCenter.default.removeObserver(powerOffObserver)
            self.powerOffObserver = nil
        }

        refreshTask?.cancel()
        refreshTask = nil
        batteryFetchTask?.cancel()
        batteryFetchTask = nil
        batteryPollingTask?.cancel()
        batteryPollingTask = nil

        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        for task in errorClearTasks.values { task.cancel() }
        errorClearTasks.removeAll()
    }

    // MARK: - Refresh

    /// Rebuilds `pairedDevices` from the current IOBluetooth snapshot.
    /// Call on popup-appear and after any CoreAudio device list change.
    func refresh() {
        guard powerOnObserver != nil else {
            logger.debug("BluetoothDeviceMonitor not started, skipping refresh")
            return
        }
        refreshTask?.cancel()
        refreshTask = Task {
            let powered = await Self.runOnBTQueue {
                IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
            }
            guard !Task.isCancelled else { return }

            isBluetoothOn = powered

            guard powered else {
                let connectingSnapshot = connectingIDs
                let rawDevices = await Self.runOnBTQueue {
                    Self.fetchPairedAudioDevices(excludingConnectingIDs: connectingSnapshot)
                }
                guard !Task.isCancelled else { return }

                let devices = rawDevices.map { raw in
                    return PairedBluetoothDevice(
                        id: raw.mac,
                        name: raw.name,
                        icon: NSImage(
                            systemSymbolName: raw.iconName,
                            accessibilityDescription: raw.name
                        ),
                        isConnected: false
                    )
                }
                pairedDevices = devices

                var audioDevices: [PairedBluetoothDevice] = []
                for i in 0..<rawDevices.count {
                    if rawDevices[i].isAudio {
                        audioDevices.append(devices[i])
                    }
                }
                pairedAudioDevices = audioDevices
                deviceBatteryLevels = [:]
                return
            }

            let connectingSnapshot = connectingIDs
            let rawDevices = await Self.runOnBTQueue {
                Self.fetchPairedAudioDevices(excludingConnectingIDs: connectingSnapshot)
            }
            guard !Task.isCancelled else { return }

            let devices = rawDevices.map { raw in
                let isConnectedOverride = raw.isConnected || disconnectingIDs.contains(raw.mac)
                return PairedBluetoothDevice(
                    id: raw.mac,
                    name: raw.name,
                    icon: NSImage(
                        systemSymbolName: raw.iconName,
                        accessibilityDescription: raw.name
                    ),
                    isConnected: isConnectedOverride
                )
            }
            pairedDevices = devices

            var audioDevices: [PairedBluetoothDevice] = []
            for i in 0..<rawDevices.count {
                if rawDevices[i].isAudio {
                    audioDevices.append(devices[i])
                }
            }
            pairedAudioDevices = audioDevices

            logger.debug("Paired BT devices: \(devices.count), Audio: \(audioDevices.count)")

            // Fetch battery levels asynchronously in the background so it doesn't block refresh
            triggerBatteryUpdate()
        }
    }

    private func triggerBatteryUpdate() {
        batteryFetchTask?.cancel()
        batteryFetchTask = Task {
            // Run system_profiler on a background thread
            let battery = await Task.detached(priority: .background) {
                Self.fetchSystemBluetoothBattery()
            }.value

            guard !Task.isCancelled else { return }
            self.deviceBatteryLevels = battery
        }
    }

    // MARK: - Connect

    /// Initiates a Bluetooth connection for the given paired device.
    func connect(device: PairedBluetoothDevice) {
        let mac = device.id
        if connectingIDs.contains(mac) {
            logger.info("Cancelling connection attempt to \(device.name) (\(mac))")
            cancelConnectionAttempt(mac: mac)
            return
        }

        logger.info("Connecting to \(device.name) (\(mac))")

        connectingIDs.insert(mac)
        connectionErrors.removeValue(forKey: mac)

        let task = Task {
            let powered = await Self.runOnBTQueue {
                IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
            }
            
            if !powered {
                self.logger.info("Bluetooth is off. Enabling Bluetooth programmatically first...")
                _ = IOBluetoothPreferenceSetControllerPowerState(1)
                // Wait for the controller to initialize (approx 2s)
                try? await Task.sleep(for: .seconds(2.0))
            }

            let result = await Self.runOnBTQueue {
                let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
                guard let btDevice = all.first(where: { $0.addressString == mac }) else {
                    return kIOReturnNotFound
                }
                return btDevice.openConnection()
            }

            guard !Task.isCancelled else {
                logger.info("Connection task cancelled for \(device.name)")
                return
            }

            if result != kIOReturnSuccess {
                logger.error("\(device.name): openConnection failed (IOReturn \(result))")
                finishConnecting(mac: mac, name: device.name, error: "Couldn't connect")
                return
            }

            // Start polling connection state in the background (works for both audio and non-audio devices)
            startConnectPolling(mac: mac, name: device.name)
        }
        connectionTasks[mac] = task
    }

    private func cancelConnectionAttempt(mac: String) {
        connectionTasks[mac]?.cancel()
        connectionTasks.removeValue(forKey: mac)
        timeoutTasks[mac]?.cancel()
        timeoutTasks.removeValue(forKey: mac)
        connectingIDs.remove(mac)
        refresh()
    }

    /// Called when a new CoreAudio output device appears.
    /// Refreshes the paired list.
    func notifyDeviceAppearedInCoreAudio() {
        refresh()
    }

    // MARK: - IOBluetooth Queue Helper

    /// Runs a closure on the dedicated Bluetooth serial queue and returns the result.
    /// Bridges DispatchQueue → Swift concurrency via `withCheckedContinuation`.
    private nonisolated static func runOnBTQueue<T: Sendable>(
        _ work: @Sendable @escaping () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            btQueue.async {
                autoreleasepool {
                    continuation.resume(returning: work())
                }
            }
        }
    }

    // MARK: - Background IOBluetooth Work

    /// Sendable snapshot of a paired device — transfers safely across actor boundaries.
    private struct RawPairedDevice: Sendable {
        let mac: String
        let name: String
        let iconName: String
        let isConnected: Bool
        let isAudio: Bool
    }

    /// Runs on btQueue. Returns filtered, sorted paired audio devices.
    private nonisolated static func fetchPairedAudioDevices(
        excludingConnectingIDs connectingIDs: Set<String>
    ) -> [RawPairedDevice] {
        guard let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        var result: [RawPairedDevice] = []

        for device in all {
            let mac = device.addressString ?? ""
            guard !mac.isEmpty else { continue }

            let hasA2DP = device.getServiceRecord(for: a2dpSinkUUID) != nil
            let hasHFP = device.getServiceRecord(for: hfpUUID) != nil
            let name = device.name ?? mac
            let isConnected = device.isConnected()
            let iconName = suggestedIconName(for: name)
            let isAudio = hasA2DP ||
                hasHFP ||
                device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) ||
                looksLikeAudioDeviceName(name)

            result.append(RawPairedDevice(mac: mac, name: name, iconName: iconName, isConnected: isConnected, isAudio: isAudio))
        }

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    private nonisolated static func looksLikeAudioDeviceName(_ name: String) -> Bool {
        let lowercaseName = name.lowercased()
        return lowercaseName.contains("airpods") ||
            lowercaseName.contains("beats") ||
            lowercaseName.contains("headphone") ||
            lowercaseName.contains("headset") ||
            lowercaseName.contains("earbud") ||
            lowercaseName.contains("speaker")
    }

    /// Pure function — safe to call from any thread.
    private nonisolated static func suggestedIconName(for name: String) -> String {
        let lowercaseName = name.lowercased()
        if lowercaseName.contains("airpods pro") { return "airpodspro" }
        if lowercaseName.contains("airpods max") { return "airpodsmax" }
        if lowercaseName.contains("airpods") { return "airpods.gen3" }
        if lowercaseName.contains("homepod mini") { return "homepodmini" }
        if lowercaseName.contains("homepod") { return "homepod" }
        if lowercaseName.contains("beats") { return "beats.headphones" }
        if lowercaseName.contains("mouse") || lowercaseName.contains("m650") || lowercaseName.contains("logi") { return "computermouse" }
        if lowercaseName.contains("keyboard") || lowercaseName.contains("keychron") { return "keyboard" }
        return "headphones"
    }

    // MARK: - Private Helpers

    private func startConnectPolling(mac: String, name: String) {
        timeoutTasks[mac]?.cancel()
        timeoutTasks[mac] = Task { [weak self, connectTimeoutSeconds] in
            let startTime = Date()
            let timeout = startTime.addingTimeInterval(connectTimeoutSeconds)
            
            while Date() < timeout {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                
                let isConnected = await Self.runOnBTQueue {
                    let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
                    guard let btDevice = all.first(where: { $0.addressString == mac }) else {
                        return false
                    }
                    return btDevice.isConnected()
                }
                
                if isConnected {
                    self?.logger.info("Device \(name) connected successfully detected by polling")
                    self?.finishConnecting(mac: mac, name: name, error: nil)
                    return
                }
            }
            
            guard !Task.isCancelled else { return }
            self?.logger.warning("\(name) connect timeout after \(connectTimeoutSeconds)s")
            self?.finishConnecting(mac: mac, name: name, error: t("Connection timed out"))
        }
    }

    private func finishConnecting(mac: String, name: String, error: String?) {
        connectionTasks[mac]?.cancel()
        connectionTasks.removeValue(forKey: mac)
        timeoutTasks[mac]?.cancel()
        timeoutTasks.removeValue(forKey: mac)
        connectingIDs.remove(mac)

        if let error {
            connectionErrors[mac] = error
            scheduleErrorClear(mac: mac)
        } else {
            startBatteryPolling(deviceName: name)
        }

        refresh()
    }

    private func scheduleErrorClear(mac: String) {
        errorClearTasks[mac]?.cancel()
        errorClearTasks[mac] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.connectionErrors.removeValue(forKey: mac)
        }
    }

    /// Disconnects a connected Bluetooth device using closeConnection().
    func disconnect(device: PairedBluetoothDevice) {
        let mac = device.id
        guard !disconnectingIDs.contains(mac) else { return }

        logger.info("Disconnecting from \(device.name) (\(mac))")
        disconnectingIDs.insert(mac)
        
        // Cancel battery polling since we are disconnecting
        batteryPollingTask?.cancel()
        batteryPollingTask = nil
        
        Task {
            let result = await Self.runOnBTQueue {
                let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
                guard let btDevice = all.first(where: { $0.addressString == mac }) else {
                    return kIOReturnNotFound
                }
                return btDevice.closeConnection()
            }
            if result != kIOReturnSuccess {
                logger.error("\(device.name): closeConnection failed (IOReturn \(result))")
            }
            
            // Poll for actual disconnection state to clean up disconnectingID
            startDisconnectPolling(mac: mac, name: device.name)
        }
    }

    private func startDisconnectPolling(mac: String, name: String) {
        Task { [weak self] in
            let startTime = Date()
            let timeout = startTime.addingTimeInterval(5.0) // 5 seconds max polling
            
            while Date() < timeout {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                
                let isConnected = await Self.runOnBTQueue {
                    let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
                    guard let btDevice = all.first(where: { $0.addressString == mac }) else {
                        return false
                    }
                    return btDevice.isConnected()
                }
                
                if !isConnected {
                    self?.logger.info("Device \(name) disconnected successfully detected by polling")
                    break
                }
            }
            
            self?.disconnectingIDs.remove(mac)
            self?.refresh()
        }
    }

    private func startBatteryPolling(deviceName: String) {
        batteryPollingTask?.cancel()
        batteryPollingTask = Task { [weak self] in
            self?.logger.debug("Starting battery polling for \(deviceName)")
            // Poll battery status every 1.5 seconds for up to 6 times (9 seconds total)
            for i in 0..<6 {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                
                let battery = await Task.detached(priority: .background) {
                    Self.fetchSystemBluetoothBattery()
                }.value
                
                guard !Task.isCancelled else { return }
                
                if let self = self {
                    self.deviceBatteryLevels = battery
                    if battery[deviceName] != nil {
                        self.logger.info("Battery level for \(deviceName) successfully retrieved on poll #\(i + 1).")
                        break
                    }
                }
            }
        }
    }

    /// Runs system_profiler SPBluetoothDataType to fetch connected AirPods battery levels.
    private nonisolated static func fetchSystemBluetoothBattery() -> [String: BluetoothBatteryStatus] {
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPBluetoothDataType"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return parseSystemProfilerBattery(output)
            }
        } catch {
            // Ignore error
        }
        return [:]
    }

    private nonisolated static func parseSystemProfilerBattery(_ output: String) -> [String: BluetoothBatteryStatus] {
        var results: [String: BluetoothBatteryStatus] = [:]
        let lines = output.components(separatedBy: .newlines)
        
        var currentDeviceName: String? = nil
        var left: Int? = nil
        var right: Int? = nil
        var caseBattery: Int? = nil
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if line.hasPrefix("          ") && !line.hasPrefix("            ") && trimmed.hasSuffix(":") {
                let name = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                if !name.isEmpty {
                    if let prevName = currentDeviceName, left != nil || right != nil || caseBattery != nil {
                        results[prevName] = BluetoothBatteryStatus(left: left, right: right, caseBattery: caseBattery)
                    }
                    currentDeviceName = name
                    left = nil
                    right = nil
                    caseBattery = nil
                }
            }
            
            if trimmed.hasPrefix("Left Battery Level:") {
                left = parsePercentage(trimmed)
            } else if trimmed.hasPrefix("Right Battery Level:") {
                right = parsePercentage(trimmed)
            } else if trimmed.hasPrefix("Case Battery Level:") {
                caseBattery = parsePercentage(trimmed)
            }
        }
        
        if let prevName = currentDeviceName, left != nil || right != nil || caseBattery != nil {
            results[prevName] = BluetoothBatteryStatus(left: left, right: right, caseBattery: caseBattery)
        }
        
        return results
    }

    private nonisolated static func parsePercentage(_ line: String) -> Int? {
        let digits = line.filter { $0.isNumber }
        return Int(digits)
    }

}

/// Structure representing battery levels of a Bluetooth accessory.
struct BluetoothBatteryStatus: Sendable, Hashable {
    let left: Int?
    let right: Int?
    let caseBattery: Int?
}
