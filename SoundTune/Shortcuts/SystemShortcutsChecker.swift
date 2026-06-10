// SoundTune/Shortcuts/SystemShortcutsChecker.swift
import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.soundtune.SoundTune", category: "SystemShortcutsChecker")

struct SystemShortcutConflict: Hashable, Identifiable {
    var id: String { "\(name)-\(keyName)" }
    let name: String
    let keyName: String
}

enum SystemShortcutsChecker {
    /// Reads ~/Library/Preferences/com.apple.symbolichotkeys.plist and checks for F-key conflicts.
    static func checkConflicts() -> [SystemShortcutConflict] {
        var conflicts: [SystemShortcutConflict] = []
        
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences/com.apple.symbolichotkeys.plist")
        guard let plist = NSDictionary(contentsOfFile: path),
              let symbolichotkeys = plist["AppleSymbolicHotKeys"] as? [String: Any] else {
            return []
        }
        
        // standard macOS Symbolic Hotkey IDs:
        // 32, 33: Show Desktop (F11 by default)
        // 34, 35: Mission Control (F9 by default)
        // 36, 37: Application Windows (F10 by default)
        // 70, 71: Show Dashboard (F12 by default in older macOS)
        let keysToCheck: [(id: String, name: String)] = [
            ("32", "Show Desktop"),
            ("33", "Show Desktop"),
            ("34", "Mission Control"),
            ("35", "Mission Control"),
            ("36", "Application Windows"),
            ("37", "Application Windows"),
            ("70", "Show Dashboard"),
            ("71", "Show Dashboard")
        ]
        
        for check in keysToCheck {
            if let entry = symbolichotkeys[check.id] as? [String: Any],
               let enabled = entry["enabled"] as? Bool,
               enabled {
                
                if let value = entry["value"] as? [String: Any],
                   let parameters = value["parameters"] as? [Int],
                   parameters.count >= 2 {
                    let keyCode = parameters[1]
                    let keyName = getFKeyName(keyCode: keyCode)
                    if !keyName.isEmpty {
                        // Avoid duplicates
                        if !conflicts.contains(where: { $0.name == check.name && $0.keyName == keyName }) {
                            conflicts.append(SystemShortcutConflict(name: check.name, keyName: keyName))
                        }
                    }
                }
            }
        }
        return conflicts
    }
    
    /// Translates key codes to human-readable F-key names
    private static func getFKeyName(keyCode: Int) -> String {
        switch keyCode {
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return ""
        }
    }
    
    /// Opens macOS System Settings directly to the Keyboard Shortcuts pane
    static func openKeyboardShortcutsSettings() {
        let script = """
        tell application "System Settings"
            activate
            reveal anchor "Shortcuts" of pane id "com.apple.Keyboard-Settings.extension"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                logger.error("AppleScript error opening keyboard shortcuts pane: \(error)")
                // Fallback to opening Keyboard settings pane URL directly
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
