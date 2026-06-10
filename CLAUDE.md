# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build (Debug)
xcodebuild -project SoundTune.xcodeproj -scheme SoundTune -configuration Debug \
  -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution build

# Run all tests
xcodebuild -project SoundTune.xcodeproj -scheme SoundTune -configuration Debug \
  -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution test

# Run a single test suite by name (Swift Testing uses -only-testing with the suite name)
xcodebuild -project SoundTune.xcodeproj -scheme SoundTune -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:SoundTuneTests/BiquadMathTests test
```

Use the macOS destination for local work. There is no separate lint step.

```bash
# Build Release .app (ad-hoc signed, no Developer ID)
xcodebuild -project SoundTune.xcodeproj -scheme SoundTune -configuration Release \
  -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution \
  -derivedDataPath /tmp/SoundTuneBuild \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
# Output: /tmp/SoundTuneBuild/Build/Products/Release/SoundTune.app
```

The app is distributed without a Developer ID (ad-hoc signed). Users bypass the Gatekeeper prompt via System Settings → Privacy & Security → Open Anyway, or right-click → Open.

## Architecture Overview

SoundTune is a macOS menu-bar audio control app (LSUIElement agent — no Dock icon). It intercepts per-app audio using CoreAudio CATap (requires Screen & System Audio Recording permission) and exposes per-app volume, mute, boost, EQ, device routing, AutoEQ, device priority, media keys, HUD, and hotkeys from a `FluidMenuBarExtra` popup/settings surface.

### Service graph (UI-facing services are generally `@Observable @MainActor`)

```text
SoundTuneApp (@main)
├── AudioEngine              — core orchestrator; owns CATap lifecycle, device priority,
│   │                          crossfade, EQ, AutoEQ, crash recovery
│   ├── AudioProcessMonitor  — detects which PIDs are producing audio via CoreAudio
│   ├── AudioDeviceMonitor   — HAL device list; feeds device priority resolution
│   ├── DeviceVolumeMonitor  — per-device volume/mute via HAL property listeners
│   ├── BluetoothDeviceMonitor — IOBluetooth paired/connected devices + battery
│   ├── VolumeState          — per-app gain/mute/boost/device-routing in-memory store
│   ├── SettingsManager      — persisted settings JSON; app settings, routing,
│   │                          priority, hidden devices, pins/ignores, presets
│   ├── AutoEQProfileManager — headphone correction profile store
│   └── AppListCoordinator   — pin/ignore persistence + inactive-app controls
│
├── AppMediaInfoService      — AppleScript-based now-playing metadata (Coordination/)
│   │                          • infoByBundleID: [String: AppMediaInfo]  (compact row indicator)
│   │                          • nowPlayingSources: [NowPlayingSource]   (full Now Playing cards)
│   └── polls every 2 s; scans all browser tabs via Media Session JS + <video> introspection
│       NSAppleScript instances are compiled once and cached (NSCache) per script source string.
│
├── MediaControlManager      — MediaRemote.framework bridge (Coordination/)
│   │                          send play/pause/next/prev/seek to system now-playing
│   └── MRMediaRemoteSendCommand, MRMediaRemoteSetElapsedTime (READ is gated on macOS 15.4+)
│
├── MediaKeyMonitor          — CGEventTap for F10/F11/F12/volume keys (requires Accessibility)
├── MediaKeyStatus           — tap health/offline/suppression-degraded state
├── AccessibilityPermissionService — trust polling for AXIsProcessTrusted
├── PopupVisibilityService   — popup visibility + inline-settings routing for HUD/hotkeys
├── MenuBarIconCoordinator   — drives NSStatusBarButton image from volume/mute state
├── HUDWindowController      — floating volume HUD (Tahoe/classic/per-app variants)
├── MenuBarPopupController   — toggles FluidMenuBarExtra from global hotkeys
├── ShortcutsRegistry        — KeyboardShortcuts SPM wrappers + per-app hotkeys
├── TargetAppResolver        — picks the audible/frontmost app for target-app hotkeys
└── MultiOutputManager       — multi-device simultaneous output
```

### Folder layout

```text
SoundTune/
├── Audio/
│   ├── AutoEQ/        — profile catalog, fetcher, parser, processor, AutoEQSearchResult
│   ├── DDC/           — DDC/CI over I2C for external monitors (#if !APP_STORE only)
│   ├── EQ/            — BiquadMath, BiquadProcessor, EQProcessor
│   ├── Engine/        — AudioEngine + 6 extensions (Apps, AutoEQ, Health, InputLock, Routing, Watchers),
│   │                    AppListCoordinator, ProcessTapController, CrossfadeTypes, CrossfadeState,
│   │                    CrashGuard, EchoTracker, MultiOutputManager, OrphanedTapCleanup,
│   │                    SoftLimiter, TapResources, TapInitialState
│   ├── Extensions/    — AudioDeviceID+*, AudioObjectID+* (HAL API wrappers)
│   ├── Keys/          — MediaKeyMonitor, MediaKeyEventDecoder
│   ├── Loudness/      — ISO 226 loudness compensation pipeline
│   ├── Monitors/      — HAL monitors: AudioProcessMonitor, AudioDeviceMonitor,
│   │                    DeviceVolumeMonitor, BluetoothDeviceMonitor + their protocols
│   ├── Permission/    — AudioRecordingPermission (TCC SPI), BluetoothPermission
│   └── Types/         — AudioScope, BiquadProcessable, TransportType
├── Coordination/      — Cross-cutting services: AccessibilityPermissionService,
│                        AppMediaInfoService, MediaControlManager, MediaKeyStatus,
│                        PopupVisibilityService
├── Models/            — Pure data types: AudioApp, AudioDevice, EQSettings, VolumeState,
│                        VolumeControlTier, PinnedAppInfo, NowPlayingSource, etc.
├── Settings/
│   ├── SettingsManager.swift
│   └── Types/AppSettingsTypes.swift  — MenuBarIconStyle, HUDStyle, AppearancePreference,
│                                        MenuBarPopupSize, VolumeHotkeyStep
├── Shortcuts/         — ShortcutsRegistry, ShortcutAction, ShortcutCodable,
│                        SystemShortcutsChecker, MenuBarPopupController, TargetAppResolver
├── Utilities/         — DeviceIconCache, ProcessNameLookup, URLHandler
└── Views/
    ├── Components/    — All reusable SwiftUI components, including EQPanelView, EQSliderView,
    │                    BluetoothPermissionPrompt, NowPlayingCard, LiquidGlassSlider, etc.
    ├── DesignSystem/  — DesignTokens, Localization (t("...")), ViewModifiers, window bridges
    ├── HUD/           — HUDWindowController, TahoeStyleHUD, ClassicStyleHUD
    ├── MenuBar/       — MenuBarIconCoordinator, MenuBarIconState, PopupKeyboardNavModel
    ├── Onboarding/    — OnboardingView
    ├── Previews/      — MockData, PreviewContainer (dev only)
    ├── Rows/          — AppRow, AppRowControls, AppRowWithLevelPolling, AppEditRow,
    │   │                DeviceRow, DeviceEditRow, InactiveAppRow, BluetoothConnectedRow,
    │   │                PairedDeviceRow, InputDeviceRow
    │   └── DeviceInspector/  — DeviceInspectorInfo, DeviceInspectorInfoGrid, DeviceInspectorViewModel
    ├── Settings/      — SettingsRootView + MediaKeyOfflineCard + Components/ (SettingsRow,
    │                      SettingsSection, ThemeTilePicker, HUDStyleSegmentedControl,
    │                      IconStyleSegmentedControl, VolumeSlider, etc.)
    ├── Sheets/        — DeviceDetailSheet
    └── MenuBarPopupView.swift  — main popup (1700+ lines); top-level popup orchestration only
```

### Key flows

**Per-app audio interception:** `AudioProcessMonitor` discovers PIDs → `AudioEngine` creates a `ProcessTapController` (CATap) per PID → the tap callback applies gain, mute, boost, EQ, AutoEQ, loudness, and limiter state → `DeviceVolumeMonitor` applies device-level volume via the selected hardware/DDC/software tier.

**App list surface:** `AudioEngine.displayableApps` filters ignored apps, then returns pinned active apps, pinned inactive apps, and unpinned active apps in stable alphabetical groups. Pin/ignore persistence and inactive-app edits live in `AppListCoordinator`; live tap teardown/re-apply stays in `AudioEngine`.

**Now Playing cards:** `AudioProcessMonitor` signals active PIDs → `AudioEngine.apps` updates → `MenuBarPopupView.onChange(of: audioEngine.apps)` calls `appMediaService.setActiveApps()` → service polls AppleScript every 2 s → `nowPlayingSources` drives `ForEach` of `NowPlayingCard` views.

**Transport routing in `MenuBarPopupView`:**

- `.browserFrontTab` → play/pause via JS injection (`playPauseBrowserFrontTab`) / seek via `mediaManager.seek(to:)` (MR system command — Chrome routes it to its internal player, bypassing DRM restrictions)
- `.browserBackground` non-DRM → `playPauseBrowserBackground(source:)` / `seek(source:to:)` (JS injection)
- `.musicApp` → `appMediaService.playPause/next/previous/seek` (AppleScript)
- next/previous are hidden for browser tabs (`canSkip: false`) — they would incorrectly target the OS "now playing" app (e.g. Spotify)

**Media keys and HUD:** `MediaKeyMonitor` installs a `CGEventTap` only when media key control is enabled and Accessibility is trusted. It swallows F10/F11/F12/volume keys, coalesces fast DDC repeats, updates the default output tier, flashes the menu bar icon, and shows `HUDWindowController` unless the popup is visible or the foreground app is fullscreen. `MediaKeyStatus` tracks tap-offline/degraded states shown in Settings.

**Global hotkeys:** `ShortcutsRegistry` loads `SettingsManager.appSettings.customShortcuts` into `KeyboardShortcuts`, registers key-down/up handlers, and mirrors Recorder changes back into settings. Target-app volume/mute actions use `TargetAppResolver` to prefer the frontmost audible app, then the last target, then the first audible candidate.

**Device priority resolution:** `SettingsManager.devicePriorityOrder` / `inputDevicePriorityOrder` ([String] of UIDs) + `AudioDeviceMonitor` alive-check → `AudioEngine` selects the highest-priority live output/input, watches not-yet-alive devices, and restores after macOS auto-switches.

**Settings and onboarding:** `SoundTuneApp` owns a real Settings scene plus an inline popup settings path. `OnboardingLauncher` opens the onboarding window once while `hasCompletedOnboarding` is false; `SettingsManager.appSettings` persists launch-at-login, language, appearance, popup size, HUD style, media key state, hotkey step, custom shortcuts, and multi-output selections.

**Echo suppression:** `EchoTracker` prevents feedback loops when `AudioEngine` itself triggers a default-device change (e.g. restoring after macOS auto-switches). The tracker stamps the UID; the HAL notification handler consumes it and skips re-entrant handling.

**Crash recovery:** `CrashGuard` installs a signal handler that destroys all live CoreAudio aggregate devices via Mach IPC to `coreaudiod` before re-raising the signal. Uses a fixed-size C buffer (`nonisolated(unsafe)`) for async-signal safety — no heap operations in the handler.

**`ProcessTapController` thread model:** The protocol surface and setup/teardown path are `@MainActor`, but CoreAudio invokes the HAL I/O callback on a real-time audio thread. The callback reads `nonisolated(unsafe)` vars (`_volume`, `_isMuted`, EQ processors, output gate, crossfade state, etc.) written from main. All RT-safe state is intentionally marked `nonisolated(unsafe)` and must stay allocation-free/lock-free/log-free in the callback.

### App identity and persistence

Apps are keyed by `persistenceIdentifier` = bundleID if available, otherwise `"name:<processName>"`. This lets volume/mute/boost/EQ/routing settings survive PID changes between launches. `VolumeState` maps `pid_t → AppAudioState` at runtime; `SettingsManager` persists by identifier to `~/Library/Application Support/SoundTune/settings.json` (current schema version: 11). `SettingsManager.Settings` also persists pinned/ignored app metadata, hidden devices, DDC/software volume fallbacks, device tier overrides, AutoEQ favorites, user EQ presets, and app-wide `AppSettings`.

### Volume control tiers

`VolumeControlTier` (`Models/VolumeControlTier.swift`) has three values: `hardware` (HAL), `ddc` (DDC/CI over USB for external monitors), `software` (CoreAudio gain). Auto-detection picks the best available tier; users can override via the device detail sheet. DDC support is compiled out in App Store builds (`#if !APP_STORE`) — `DDCController`/`DDCService` are only present in the direct-sale target.

### Media info: two representations

- `AppMediaInfo` (in `infoByBundleID`) — one entry per app, for the compact row indicator in `AppRow`. Simple metadata: title, source, isPlaying, supportsTransport.
- `NowPlayingSource` (in `nowPlayingSources`) — one entry per browser tab or music-app track, for the full `NowPlayingCard`. Has `canSkip`, `canSeek`, `locator` (`.musicApp` / `.browserFrontTab` / `.browserBackground`).

### `soundtune://` URL scheme

External automation via `URLHandler`: `set-volumes`, `step-volume`, `set-mute`, `toggle-mute`, `set-device`, `reset`. Format: `soundtune://set-volumes?app=com.spotify.client&volume=80`.

### Important constraints

- **Sandbox is OFF; Hardened Runtime is ON.** Entitlements: `com.apple.security.automation.apple-events`, no `com.apple.security.app-sandbox`.
- **MediaRemote READ is blocked on macOS 15.4+/26.** `MRMediaRemoteGetNowPlayingInfo` returns empty. Only SEND (play/pause/next/prev/seek via `MRMediaRemoteSetElapsedTime`) works. All metadata comes from AppleScript / JS injection.
- **Netflix and DRM sites:** never use `video.currentTime = x` for seek — Netflix's Widevine player intercepts and rejects it (Chrome propagates the JS exception as AppleScript error m7375). Front-tab seek must use `mediaManager.seek(to:)` (MR). Background DRM tabs have `canSeek = false`. Any JS seek must be wrapped in `try{...}catch(e){}` so Chrome never propagates the exception.
- **Browser play/pause uses JS injection, not MR.** Using `MRMediaRemoteSendCommand(play)` for a browser front tab routes to the OS "now playing" app (e.g. Spotify in the background). JS injection targets the correct tab.
- **AppleScript reserved words:** do not use `result` as a variable name inside AppleScript scripts (it's a built-in constant for the last expression value). Use `outStr` or similar.
- **Card order stability:** `nowPlayingSources` order must never change except on explicit user reorder. Capture `existingIDs` at the very start of `pollOnce()` before any `await` calls; sort new sources against it after all awaits complete.
- **Media keys vs hotkeys:** `MediaKeyMonitor` requires Accessibility because it swallows system media keys with a `CGEventTap`. `KeyboardShortcuts` global hotkeys are Carbon-backed and do not require Accessibility.
- **Termination behavior:** `SoundTuneApp` removes the default app termination command and `AppDelegate.applicationShouldTerminate` rejects termination unless the right-click "Quit SoundTune" menu explicitly sets `allowTermination`.

## Code Conventions

### Localization

All user-visible strings go through `t("...")` (defined in `Views/DesignSystem/Localization.swift`). The English + Turkish translation table is embedded in `LanguageManager`; add both languages when introducing a new UI string. Never hardcode UI strings.

### Design system

Colors, typography, spacing, and corner radii all come from `DesignTokens`. Dynamic colors must use `DesignTokens.dynamicColor(name:light:dark:)` with a unique `name` string — this is validated in `DesignTokensDynamicResolutionTests`.

### `@Observable` pattern

UI-facing state services generally use the `Observation` framework (`@Observable`, NOT `ObservableObject`/`@Published`). Views access service properties directly; SwiftUI tracks them automatically. Bindable wrappers (`@Bindable`) are used in views that need two-way binding. Small coordinators that do not expose observed UI state can remain plain `@MainActor` types.

### Concurrency

`@MainActor` is used on all classes that touch UI or audio state. Heavy work (AppleScript execution, image downloads) runs on background queues/tasks with explicit `await MainActor.run { }` hops. The AppleScript serial queue (`scriptQueue`) is `nonisolated` — never dispatch to it from `@MainActor` synchronously. Optimistic UI updates (e.g. toggling `isPlaying` before the AppleScript round-trip) are the standard pattern for transport controls.

### Protocol seams for testing

`AudioProcessMonitoring`, `DeviceVolumeProviding`, `AudioDeviceProviding`, and `ProcessTapControlling` are protocols so `AudioEngine` can be unit-tested with mock injections. Keep new engine dependencies behind a protocol when testability matters.

### Tests

All tests use **Swift Testing** (`import Testing`, `@Suite`, `@Test`) — not XCTest. `@testable import SoundTune` is the standard import. Snapshot tests use `swift-snapshot-testing`.

### Logging

Use `os.Logger` everywhere — `Logger(subsystem: "com.soundtune.SoundTune", category: "<TypeName>")`. Never use `print()` in production code.

## SPM Dependencies

| Package | Purpose |
| --- | --- |
| `FluidMenuBarExtra` | Menu bar popup rendering |
| `KeyboardShortcuts` | Global hotkey binding (Carbon-backed, no Accessibility needed) |
| `swift-snapshot-testing` | UI snapshot tests (test target only) |
