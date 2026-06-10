// SoundTune/Models/NowPlayingSource.swift
import AppKit

/// A single "now playing" source — one browser tab or one music-app track.
/// Replaces the single-source AppMediaInfo in the Now Playing section; AppMediaInfo
/// stays intact for the compact per-row indicator in AppRow.
struct NowPlayingSource: Identifiable {

    enum Kind { case browserTab, musicApp }

    /// Where and how to send transport/seek commands for this source.
    enum Locator {
        /// Scriptable music app (Spotify, Apple Music, VLC).
        case musicApp(bundleID: String)
        /// Active/front tab at the time of polling. The indices are kept so controls
        /// can target the same tab even if the user focuses another media tab.
        case browserFrontTab(bundleID: String, windowIndex: Int, tabIndex: Int)
        /// Any other browser tab — use direct JS injection.
        case browserBackground(bundleID: String, windowIndex: Int, tabIndex: Int)
    }

    let id: String              // bundleID for music; stable browser source key for tabs
    let kind: Kind
    var title: String
    var subtitle: String        // artist or site host
    var artwork: NSImage?
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var canTransport: Bool
    var canSkip: Bool           // false for browser tabs (prev/next route to wrong app)
    var canSeek: Bool           // false for DRM background tabs or unknown duration
    let locator: Locator
    let appBundleID: String     // bundle ID of the host app (for icon lookup)
    let sourceURL: String?      // browser tab URL, used to verify stale tab indices
}

extension NowPlayingSource {
    /// True for known DRM streaming sites where raw <video> seek would error.
    var isDRMSource: Bool {
        guard kind == .browserTab else { return false }
        let h: String
        if let sourceURL, let host = URL(string: sourceURL)?.host?.lowercased() {
            h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else {
            h = subtitle.lowercased()
        }
        let drm = ["netflix.com", "primevideo.com", "disneyplus.com",
                   "max.com", "hbomax.com", "hulu.com", "peacocktv.com", "paramountplus.com"]
        return drm.contains(where: { h == $0 || h.hasSuffix("." + $0) })
    }
}

extension NowPlayingSource: Equatable {
    static func == (lhs: NowPlayingSource, rhs: NowPlayingSource) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isPlaying == rhs.isPlaying
            && Int(lhs.position) == Int(rhs.position)
            && Int(lhs.duration) == Int(rhs.duration)
            && lhs.sourceURL == rhs.sourceURL
            && lhs.artwork === rhs.artwork
    }
}
