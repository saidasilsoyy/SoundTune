// SoundTune/SoundTuneApp.swift
import SwiftUI
import UserNotifications
import FluidMenuBarExtra
import AppKit
import os

private let logger = Logger(subsystem: "com.soundtune.SoundTune", category: "App")

@MainActor
private final class PermissionPopupFlowCoordinator {
    private let popupVisibility: PopupVisibilityService
    private let popupController: MenuBarPopupController
    private var shouldReopenPopup = false
    private var shouldReopenSettings = false
    private var reopenTask: Task<Void, Never>?

    init(
        popupVisibility: PopupVisibilityService,
        popupController: MenuBarPopupController
    ) {
        self.popupVisibility = popupVisibility
        self.popupController = popupController
    }

    func permissionRequestStarted(reopenSettings: Bool) {
        guard popupVisibility.isVisible else {
            shouldReopenPopup = false
            shouldReopenSettings = false
            return
        }

        shouldReopenPopup = true
        shouldReopenSettings = reopenSettings

        if let keyWindow = NSApp.keyWindow,
           String(describing: type(of: keyWindow)).contains("FluidMenuBarExtra") {
            keyWindow.resignKey()
            keyWindow.orderOut(nil)
        }
        popupVisibility.isVisible = false
    }

    func permissionGranted() {
        guard shouldReopenPopup else { return }
        shouldReopenPopup = false
        popupVisibility.shouldShowSettingsInline = shouldReopenSettings
        shouldReopenSettings = false

        reopenTask?.cancel()
        reopenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self,
                  !self.popupVisibility.isVisible else { return }
            self.popupController.toggle()
            self.reopenTask = nil
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static private(set) var shared: AppDelegate?

    var audioEngine: AudioEngine?

    /// Only our right-click "Quit SoundTune" menu sets this to true before calling
    /// terminate(_:). All other termination requests (⌘Q, etc.) are rejected.
    var allowTermination = false

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        allowTermination ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine = audioEngine else {
            return
        }
        let urlHandler = URLHandler(audioEngine: audioEngine)

        for url in urls {
            urlHandler.handleURL(url)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// LSUIElement agent — closing the Settings window must not terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationAllowsToRestoreState(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct SoundTuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioEngine: AudioEngine
    @State private var deviceVolumeMonitor: DeviceVolumeMonitor
    @State private var accessibility: AccessibilityPermissionService
    @State private var mediaKeyStatus: MediaKeyStatus
    @State private var popupVisibility: PopupVisibilityService
    @State private var hudController: HUDWindowController
    @State private var mediaKeyMonitor: MediaKeyMonitor
    @State private var iconCoordinator: MenuBarIconCoordinator
    @State private var menuBarPopupController: MenuBarPopupController
    @State private var shortcutsRegistry: ShortcutsRegistry
    @State private var resolver: TargetAppResolver
    @State private var appMediaService: AppMediaInfoService
    @State private var showMenuBarExtra = true

    /// Snapshot icon computed at launch from the user's chosen style and the current
    /// default-device volume/mute. The coordinator keeps it in sync afterwards.
    private let launchIconImage: NSImage

    var body: some Scene {
        Window(t("Welcome to SoundTune"), id: "onboarding") {
            OnboardingView(
                settings: audioEngine.settingsManager,
                accessibility: accessibility,
                permission: audioEngine.permission,
                bluetoothPermission: audioEngine.bluetoothPermission
            )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 480)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { content, context in
            let displayBounds = context.defaultDisplay.visibleRect
            let size = CGSize(width: 520, height: 480)
            let position = CGPoint(
                x: displayBounds.midX - (size.width / 2),
                y: displayBounds.midY - (size.height / 2)
            )
            return WindowPlacement(position, size: size)
        }
        // Remove the default ⌘Q "Quit" command so the app can only be quit via the
        // right-click menu's "Quit SoundTune" item. Belt-and-suspenders with
        // AppDelegate.applicationShouldTerminate, which already rejects stray terminate(_:).
        .commands {
            CommandGroup(replacing: .appTermination) { }
        }

        // Declared before FluidMenuBarExtra so this Settings scene wins over
        // FluidMenuBarExtra's `Settings {}` placeholder. Both ⌘, and the
        // gear button route here via openSettings().
        Settings {
            SettingsRootView(
                settings: audioEngine.settingsManager,
                audioEngine: audioEngine,
                deviceVolumeMonitor: deviceVolumeMonitor,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                mediaKeyMonitor: mediaKeyMonitor,
                shortcutsRegistry: shortcutsRegistry
            )
        }
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { content, context in
            let displayBounds = context.defaultDisplay.visibleRect
            let size = CGSize(width: 520, height: 480)
            let position = CGPoint(
                x: displayBounds.midX - (size.width / 2),
                y: displayBounds.midY - (size.height / 2)
            )
            return WindowPlacement(position, size: size)
        }

        FluidMenuBarExtra("SoundTune", image: launchIconImage, isInserted: $showMenuBarExtra, menu: iconCoordinator.makeContextMenu()) {
            menuBarContent
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        // `deviceVolumeMonitor` is declared as `any DeviceVolumeProviding` on
        // AudioEngine so tests can inject mocks; in production it's always the
        // concrete `DeviceVolumeMonitor` that this view consumes directly.
        MenuBarPopupView(
            audioEngine: audioEngine,
            deviceVolumeMonitor: deviceVolumeMonitor,
            shortcutsRegistry: shortcutsRegistry,
            permission: audioEngine.permission,
            bluetoothPermission: audioEngine.bluetoothPermission,
            accessibility: accessibility,
            mediaKeyStatus: mediaKeyStatus,
            popupVisibility: popupVisibility,
            hudController: hudController,
            mediaKeyMonitor: mediaKeyMonitor,
            appMediaService: appMediaService
        )
        .task {
            // Idempotent: subsequent task runs (popup re-open) are no-ops inside start().
            shortcutsRegistry.start()
        }
        .background(OnboardingLauncher(settings: audioEngine.settingsManager))
        .background(PopupFlashSuppressor())
    }

    init() {
        // Disable macOS automatic window state restoration so windows don't reopen on launch.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        
        // Install crash handler to clean up aggregate devices on abnormal exit
        CrashGuard.install()
        // Destroy any orphaned aggregate devices from previous crashes
        OrphanedTapCleanup.destroyOrphanedDevices()

        let settings = SettingsManager()
        let profileManager = AutoEQProfileManager()
        let permission = AudioRecordingPermission()
        let engine = AudioEngine(permission: permission, settingsManager: settings, autoEQProfileManager: profileManager)
        guard let concreteVolumeMonitor = engine.deviceVolumeMonitor as? DeviceVolumeMonitor else {
            preconditionFailure("SoundTuneApp requires AudioEngine to use DeviceVolumeMonitor in production")
        }
        _audioEngine = State(initialValue: engine)
        _deviceVolumeMonitor = State(initialValue: concreteVolumeMonitor)

        // Media keys / HUD services — instantiated at app scope so the tap
        // and HUD panel outlive popup open/close cycles.
        let accessibilityService = AccessibilityPermissionService()
        let statusService = MediaKeyStatus()
        let popupService = PopupVisibilityService()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: statusService, popupVisibility: popupService)

        // Wire the interactive Tahoe slider back to the device volume monitor.
        // Mirrors the mute semantics applied for media-key drags (auto-unmute
        // when ramping above 0 from muted; auto-mute when dragging down to 0)
        // so the HUD slider and F11/F12 behave identically.
        hud.volumeWriter = { [weak engine] sliderFraction in
            guard let engine else { return }
            let volumeMonitor = engine.deviceVolumeMonitor
            let deviceID = volumeMonitor.defaultDeviceID
            guard deviceID.isValid else { return }
            let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
            let currentMute = volumeMonitor.muteStates[deviceID] ?? false
            let willBeSilent = sliderFraction <= 0.001
            if currentMute && !willBeSilent {
                volumeMonitor.setMute(for: deviceID, to: false)
            } else if !currentMute && willBeSilent {
                volumeMonitor.setMute(for: deviceID, to: true)
            }
            let gain = VolumeMapping.systemGain(forSliderFraction: sliderFraction, tier: tier)
            volumeMonitor.setVolume(for: deviceID, to: gain)
        }

        let monitor = MediaKeyMonitor(
            decoder: IOKitMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: accessibilityService,
            hudController: hud,
            popupVisibility: popupService,
            mediaKeyStatus: statusService
        )
        _accessibility = State(initialValue: accessibilityService)
        _mediaKeyStatus = State(initialValue: statusService)
        _popupVisibility = State(initialValue: popupService)
        _hudController = State(initialValue: hud)
        _mediaKeyMonitor = State(initialValue: monitor)

        let popupController = MenuBarPopupController()
        let permissionPopupFlow = PermissionPopupFlowCoordinator(
            popupVisibility: popupService,
            popupController: popupController
        )
        accessibilityService.onPermissionRequestStarted = { [permissionPopupFlow] in
            permissionPopupFlow.permissionRequestStarted(reopenSettings: true)
        }
        accessibilityService.onPermissionGranted = { [permissionPopupFlow] in
            permissionPopupFlow.permissionGranted()
        }
        permission.onPermissionRequestStarted = { [permissionPopupFlow] in
            permissionPopupFlow.permissionRequestStarted(reopenSettings: false)
        }
        permission.onPermissionGranted = { [permissionPopupFlow] in
            permissionPopupFlow.permissionGranted()
        }
        engine.bluetoothPermission.onPermissionRequestStarted = { [permissionPopupFlow] in
            permissionPopupFlow.permissionRequestStarted(reopenSettings: false)
        }
        engine.bluetoothPermission.onPermissionGranted = { [permissionPopupFlow] in
            permissionPopupFlow.permissionGranted()
        }
        let coordinator = MenuBarIconCoordinator(
            deviceVolumeMonitor: concreteVolumeMonitor,
            settings: settings,
            popupVisibility: popupService,
            popupController: popupController
        )
        monitor.iconCoordinator = coordinator
        // Defer start() so NSApplication.shared is fully bootstrapped before we walk NSApp.windows.
        DispatchQueue.main.async { [coordinator] in coordinator.start() }
        _iconCoordinator = State(initialValue: coordinator)

        // Render the scene's first frame with the user's chosen style instead of a generic
        // placeholder, so non-speaker styles don't briefly flash a speaker icon at launch.
        let launchVolumeMonitor = concreteVolumeMonitor
        let launchID = launchVolumeMonitor.defaultDeviceID
        let launchState = MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: launchVolumeMonitor.volumes[launchID] ?? 1.0,
            muted: launchVolumeMonitor.muteStates[launchID] ?? false,
            deviceSymbol: launchID.suggestedIconSymbol()
        )
        launchIconImage = launchState.image.nsImage()
            ?? NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "SoundTune")!

        // Start Accessibility polling immediately so `isTrustedCached` is live
        // before the user first opens Settings. The trust-flip callback wires
        // the monitor to reconcile its tap state whenever trust changes — this
        // is the single source of truth for retroactive start/stop (a `.onChange`
        // inside MenuBarPopupView would miss flips when the popup is closed).
        accessibilityService.onTrustChanged = { [weak monitor] _ in
            monitor?.reconcile()
        }
        accessibilityService.start()
        monitor.reconcile()

        // Global hotkeys (KeyboardShortcuts SPM, Carbon-backed; no Accessibility
        // permission required for the hotkey itself). Registry start() is deferred
        // to a SwiftUI `.task` on the popup content so the FluidMenuBarExtra
        // status item has been materialized before any hotkey can fire.
        let resolver = TargetAppResolver(
            ownBundleID: Bundle.main.bundleIdentifier ?? "com.soundtune.SoundTune"
        )
        resolver.start()
        let registry = ShortcutsRegistry(
            settings: settings,
            popupController: popupController,
            resolver: resolver,
            audioEngine: engine,
            hud: hud,
            popupVisibility: popupService
        )
        _menuBarPopupController = State(initialValue: popupController)
        _shortcutsRegistry = State(initialValue: registry)
        _resolver = State(initialValue: resolver)

        let mediaService = AppMediaInfoService()
        _appMediaService = State(initialValue: mediaService)
        mediaService.start()
        mediaService.setActiveApps(engine.apps)

        // Wire HUD edge-case hooks — debounced to prevent duplicate HUD shows on
        // rapid BT handshake events. The `weak` capture avoids a retain cycle since
        // `engine` lives for the duration of the app anyway, but keeps intent clear.
        var hudDebounceTask: Task<Void, Never>?

        engine.onDeviceConnectedHUD = { [weak hud, weak engine] deviceName in
            hudDebounceTask?.cancel()
            hudDebounceTask = Task { @MainActor in
                // Small delay: let CoreAudio settle and priority resolution run first
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let hud, let engine else { return }
                let monitor = engine.deviceVolumeMonitor
                let deviceID = monitor.defaultDeviceID
                let gain = monitor.volumes[deviceID] ?? 1.0
                let tier = monitor.outputVolumeBackend(for: deviceID)
                let fraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: tier)
                let muted = monitor.muteStates[deviceID] ?? false
                hud.show(sliderFraction: fraction, mute: muted, deviceName: deviceName)
            }
        }

        engine.onDeviceDisconnectedHUD = { [weak hud, weak engine] _ in
            hudDebounceTask?.cancel()
            hudDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let hud, let engine else { return }
                let monitor = engine.deviceVolumeMonitor
                let deviceID = monitor.defaultDeviceID
                guard deviceID.isValid else { return }
                let gain = monitor.volumes[deviceID] ?? 1.0
                let tier = monitor.outputVolumeBackend(for: deviceID)
                let fraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: tier)
                let muted = monitor.muteStates[deviceID] ?? false
                let fallbackName = engine.outputDevices.first(where: { $0.id == deviceID })?.name ?? ""
                hud.show(sliderFraction: fraction, mute: muted, deviceName: fallbackName)
            }
        }

        engine.onDefaultDeviceMuteChangedHUD = { [weak hud, weak engine] deviceName, isMuted in
            hudDebounceTask?.cancel()
            hudDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let hud, let engine else { return }
                let monitor = engine.deviceVolumeMonitor
                let deviceID = monitor.defaultDeviceID
                let gain = monitor.volumes[deviceID] ?? 1.0
                let tier = monitor.outputVolumeBackend(for: deviceID)
                let fraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: tier)
                hud.show(sliderFraction: fraction, mute: isMuted, deviceName: deviceName)
            }
        }

        // Pass engine to AppDelegate
        _appDelegate.wrappedValue.audioEngine = engine

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Set delegate before requesting authorization so willPresent is called
        UNUserNotificationCenter.current().delegate = _appDelegate.wrappedValue

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            // If not granted, notifications will silently not appear - acceptable behavior
        }

        // Flush debounced settings and tear down app-scope monitors before dealloc.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [settings, engine, monitor, accessibilityService, hud, coordinator, mediaService] _ in
            MainActor.assumeIsolated {
                mediaService.stop()
                coordinator.stop()
                monitor.stop()
                accessibilityService.stop()
                hud.shutdown()
                engine.shutdown()
                settings.flushSync()
            }
        }
    }
}

// MARK: - Popup flash suppressor

/// Prevents the FluidMenuBarExtra popup from briefly rendering at its initial
/// (0,0,100,100) position before the SwiftUI content size is measured and the
/// window is repositioned under the menu bar icon.
///
/// Strategy: intercept NSWindow.willBecomeKeyNotification the FIRST time the
/// popup window becomes key, hide it (alphaValue = 0), then reveal it after the
/// asynchronous setWindowFrame animation in FluidMenuBarExtra completes.
/// NSWindow.setFrame(_:display:animate:) with animate:true is synchronous and
/// blocks the main queue, so any DispatchQueue.main.async block queued before it
/// will run only after the animation finishes — guaranteeing we reveal at the
/// final, correct frame.
private final class _PopupSuppressorView: NSView {
    private nonisolated(unsafe) var windowObserver: NSObjectProtocol?
    private var didHandleFirstShow = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let window = newWindow, windowObserver == nil else { return }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, !self.didHandleFirstShow else { return }
            self.didHandleFirstShow = true
            window?.alphaValue = 0
            // Double-async: first hop waits for contentSizeDidUpdate's async block
            // to be enqueued; second hop fires after that block (and any synchronous
            // animation it triggers) has completed.
            DispatchQueue.main.async {
                DispatchQueue.main.async { [weak window] in
                    guard let window, window.isVisible else { return }
                    window.alphaValue = 1
                }
            }
        }
    }

    deinit {
        if let obs = windowObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

private struct PopupFlashSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> _PopupSuppressorView { _PopupSuppressorView() }
    func updateNSView(_ nsView: _PopupSuppressorView, context: Context) {}
}

// MARK: - Onboarding launcher

/// Transparent view placed as a .background on menuBarContent. Opens the
/// onboarding window once on first launch; subsequent task runs are no-ops
/// because hasCompletedOnboarding will already be true.
@MainActor
private struct OnboardingLauncher: View {
    let settings: SettingsManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .task {
                guard !settings.appSettings.hasCompletedOnboarding else { return }
                openWindow(id: "onboarding")
            }
    }
}
