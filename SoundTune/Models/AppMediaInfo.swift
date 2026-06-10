// SoundTune/Models/AppMediaInfo.swift
import AppKit

/// "Now playing"-style metadata for an app, gathered via AppleScript (not the
/// gated MediaRemote API). Populated for recognized browsers and scriptable
/// music players; `nil` for everything else.
struct AppMediaInfo {
    /// Primary line — browser: active tab title; music: track name.
    var title: String
    /// Secondary line — browser: site host; music: artist.
    var source: String
    /// Whether the app is currently playing (vs. paused). Browsers can't report
    /// this reliably, so it stays `false` for them and the transport row is hidden.
    var isPlaying: Bool
    /// Whether play/pause/next/previous can be sent to this app (scriptable music players only).
    var supportsTransport: Bool
    /// Favicon (browsers) or album art (music). `nil` → the row falls back to the app icon.
    var artwork: NSImage?
    /// Current playback position in seconds (0 if unknown).
    var position: Double
    /// Total duration in seconds (0 if unknown → progress bar hidden).
    var duration: Double

    init(
        title: String,
        source: String,
        isPlaying: Bool,
        supportsTransport: Bool,
        artwork: NSImage? = nil,
        position: Double = 0,
        duration: Double = 0
    ) {
        self.title = title
        self.source = source
        self.isPlaying = isPlaying
        self.supportsTransport = supportsTransport
        self.artwork = artwork
        self.position = position
        self.duration = duration
    }
}

extension AppMediaInfo: Equatable {
    // Compare artwork by identity so SwiftUI diffing stays cheap; the service
    // reuses cached NSImage instances per host/url, so identity is stable.
    static func == (lhs: AppMediaInfo, rhs: AppMediaInfo) -> Bool {
        lhs.title == rhs.title
            && lhs.source == rhs.source
            && lhs.isPlaying == rhs.isPlaying
            && lhs.supportsTransport == rhs.supportsTransport
            && lhs.artwork === rhs.artwork
            && Int(lhs.position) == Int(rhs.position)
            && Int(lhs.duration) == Int(rhs.duration)
    }
}
