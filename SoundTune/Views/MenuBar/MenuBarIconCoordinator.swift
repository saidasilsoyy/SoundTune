// SoundTune/Views/MenuBar/MenuBarIconCoordinator.swift
// Owns NSStatusBarButton.image mutation. FluidMenuBarExtra sets the image
// once at init and never touches it again, so we locate the button by
// walking NSApp.windows for the NSStatusBarButton whose accessibilityTitle
// was set to "SoundTune" by the library, and crossfade images directly.

import AppKit
import AudioToolbox
import Observation
import os

@MainActor
final class MenuBarIconCoordinator: NSObject, MediaKeyIconFlashing {
    private let deviceVolumeMonitor: DeviceVolumeMonitor
    private let settings: SettingsManager
    private let popupVisibility: PopupVisibilityService
    private let popupController: MenuBarPopupController
    private let logger = Logger(subsystem: "com.soundtune.SoundTune", category: "MenuBarIconCoordinator")

    private var flashWorkItem: DispatchWorkItem?
    private var flashActiveSymbol: String?
    private var lastObservedDeviceID: AudioDeviceID?
    private var started = false
    static var isProgrammaticSettingsOpen = false

    init(
        deviceVolumeMonitor: DeviceVolumeMonitor,
        settings: SettingsManager,
        popupVisibility: PopupVisibilityService,
        popupController: MenuBarPopupController
    ) {
        self.deviceVolumeMonitor = deviceVolumeMonitor
        self.settings = settings
        self.popupVisibility = popupVisibility
        self.popupController = popupController
        super.init()
    }

    /// Begin observing volume / mute / style and apply state to the menu bar button.
    /// Idempotent; safe to call from the app-init path even before the status item exists.
    func start() {
        guard !started else { return }
        started = true
        lastObservedDeviceID = deviceVolumeMonitor.defaultDeviceID
        attemptInitialApply(retriesLeft: 20)
        scheduleApplyTracking()
        scheduleDeviceChangeTracking()
    }

    /// Cancel pending work and drop references. Called on app termination.
    func stop() {
        flashWorkItem?.cancel()
        flashWorkItem = nil
    }

    /// Transient device-icon flash. Applies to every style; fires on media keys and device changes.
    /// If the same symbol is already flashing, extends the timer rather than restarting the fade —
    /// prevents mid-fade pops when device-change and media-key triggers coincide.
    func flashDevice() {
        let symbol = currentDeviceSymbol()
        let alreadyShowingSame = (flashActiveSymbol == symbol)
        flashActiveSymbol = symbol
        if !alreadyShowingSame {
            apply()
        }

        flashWorkItem?.cancel()
        let duration = flashDuration()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashActiveSymbol = nil
            self.apply()
        }
        flashWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    // MARK: - State

    private func computeState() -> MenuBarIconState {
        if let symbol = flashActiveSymbol {
            return .deviceFlash(symbol: symbol)
        }
        let id = deviceVolumeMonitor.defaultDeviceID
        let volume = deviceVolumeMonitor.volumes[id] ?? 0
        let muted = deviceVolumeMonitor.muteStates[id] ?? false
        return MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: volume,
            muted: muted,
            deviceSymbol: currentDeviceSymbol()
        )
    }

    private func currentDeviceSymbol() -> String {
        let id = deviceVolumeMonitor.defaultDeviceID
        guard id.isValid else { return "hifispeaker" }
        return id.suggestedIconSymbol()
    }

    private func flashDuration() -> TimeInterval {
        // Matches HUDWindowController.hideDelay so the icon and HUD fade in lockstep.
        return 1.1
    }

    // MARK: - Apply

    private func apply() {
        let buttons = resolveButtons()
        let state = computeState()
        guard let image = state.image.nsImage() else { return }
        for button in buttons {
            addFadeTransition(to: button)
            button.image = image
        }
    }

    private func attemptInitialApply(retriesLeft: Int) {
        if !resolveButtons().isEmpty {
            apply()
            return
        }
        guard retriesLeft > 0 else {
            logger.error("Menu bar button not found after 20 tries (1s); icon will remain at FluidMenuBarExtra placeholder until next state change")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.attemptInitialApply(retriesLeft: retriesLeft - 1)
        }
    }

    private func scheduleApplyTracking() {
        withObservationTracking {
            let id = deviceVolumeMonitor.defaultDeviceID
            _ = deviceVolumeMonitor.volumes[id]
            _ = deviceVolumeMonitor.muteStates[id]
            _ = settings.appSettings.menuBarIconStyle
            _ = settings.appSettings.hudStyle
        } onChange: { [weak self] in
            MainActor.assumeIsolated { [weak self] in
                self?.scheduleApplyTracking()
            }
            Task { @MainActor [weak self] in
                self?.apply()
            }
        }
    }

    private func scheduleDeviceChangeTracking() {
        withObservationTracking {
            _ = deviceVolumeMonitor.defaultDeviceID
        } onChange: { [weak self] in
            MainActor.assumeIsolated { [weak self] in
                self?.scheduleDeviceChangeTracking()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newID = self.deviceVolumeMonitor.defaultDeviceID
                if let prev = self.lastObservedDeviceID, prev != newID, newID.isValid {
                    self.flashDevice()
                }
                self.lastObservedDeviceID = newID
            }
        }
    }

    // MARK: - Button + image

    private func resolveButtons() -> [NSStatusBarButton] {
        var buttons: [NSStatusBarButton] = []
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let button = findStatusBarButton(in: contentView, matching: "SoundTune") {
                button.wantsLayer = true
                buttons.append(button)
            }
        }
        return buttons
    }

    // MARK: - Context menu

    /// Builds the right-click context menu (Settings / Quit) handed to
    /// `FluidMenuBarExtra` via its `menu:` parameter. FluidMenuBarExtra pops this
    /// natively on a plain right-click and on a control-left-click, while a plain
    /// left-click still opens the popup — the standard macOS menu-bar behaviour.
    /// Rebuilt on each call so titles pick up the current localization.
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let settingsItem = NSMenuItem(
            title: t("Settings"),
            action: #selector(openSettingsWindow),
            keyEquivalent: ""
        )
        settingsItem.target = self
        settingsItem.isEnabled = true

        if let custom = settings.appSettings.customShortcuts[ShortcutAction.openSettings.rawValue] {
            let (char, mask) = getMenuKeyEquivalent(for: custom)
            settingsItem.keyEquivalent = char
            settingsItem.keyEquivalentModifierMask = mask
        } else {
            settingsItem.keyEquivalent = ","
            settingsItem.keyEquivalentModifierMask = [.command]
        }

        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: t("Quit SoundTune"),
            action: #selector(quitApp),
            keyEquivalent: ""
        )
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        return menu
    }

    private func getMenuKeyEquivalent(for shortcut: ShortcutCodable) -> (String, NSEvent.ModifierFlags) {
        let keyCode = shortcut.keyCode
        let carbonMods = shortcut.modifiers
        
        var modifierFlags = NSEvent.ModifierFlags()
        if carbonMods & 256 != 0 { modifierFlags.insert(.command) }
        if carbonMods & 512 != 0 { modifierFlags.insert(.shift) }
        if carbonMods & 2048 != 0 { modifierFlags.insert(.option) }
        if carbonMods & 4096 != 0 { modifierFlags.insert(.control) }
        
        // Map common keycodes to characters
        let char: String = {
            switch keyCode {
            case 0: return "a"
            case 1: return "s"
            case 2: return "d"
            case 3: return "f"
            case 4: return "h"
            case 5: return "g"
            case 6: return "z"
            case 7: return "x"
            case 8: return "c"
            case 9: return "v"
            case 11: return "b"
            case 12: return "q"
            case 13: return "w"
            case 14: return "e"
            case 15: return "r"
            case 16: return "y"
            case 17: return "t"
            case 18: return "1"
            case 19: return "2"
            case 20: return "3"
            case 21: return "4"
            case 22: return "6"
            case 23: return "5"
            case 24: return "="
            case 25: return "9"
            case 26: return "7"
            case 27: return "-"
            case 28: return "8"
            case 29: return "0"
            case 30: return "]"
            case 31: return "o"
            case 32: return "u"
            case 33: return "["
            case 34: return "i"
            case 35: return "p"
            case 36: return "\r"
            case 37: return "l"
            case 38: return "j"
            case 39: return "'"
            case 40: return "k"
            case 41: return ";"
            case 42: return "\\"
            case 43: return ","
            case 44: return "/"
            case 45: return "n"
            case 46: return "m"
            case 47: return "."
            case 48: return "\t"
            case 49: return " "
            case 50: return "`"
            default:
                return ""
            }
        }()
        
        return (char, modifierFlags)
    }

    @objc internal func openSettingsWindow() {
        Self.isProgrammaticSettingsOpen = true
        popupVisibility.shouldShowSettingsInline = true
        if !popupVisibility.isVisible {
            popupController.toggle()
        }
    }

    @objc internal func quitApp() {
        if let delegate = AppDelegate.shared {
            delegate.allowTermination = true
        }
        NSApp.terminate(nil)
    }

    private func findStatusBarButton(in view: NSView, matching title: String) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton, button.accessibilityTitle() == title {
            return button
        }
        for subview in view.subviews {
            if let match = findStatusBarButton(in: subview, matching: title) {
                return match
            }
        }
        return nil
    }

    private func addFadeTransition(to button: NSStatusBarButton) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(transition, forKey: "iconFade")
    }
}
