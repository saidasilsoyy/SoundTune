// SoundTune/Coordination/AppMediaInfoService.swift
import AppKit
import Observation
import os

/// Gathers "now playing" metadata for recognized apps via AppleScript.
///
/// Produces two views of the data:
///   • `infoByBundleID` — single front-tab/active-track entry per app, used by the compact
///     row indicator in AppRow.
///   • `nowPlayingSources` — full multi-source list (all browser tabs + all music apps) for
///     the Now Playing card section. Playing sources first, then paused.
@Observable
@MainActor
final class AppMediaInfoService {

    private(set) var infoByBundleID: [String: AppMediaInfo] = [:]
    private(set) var nowPlayingSources: [NowPlayingSource] = []
    private(set) var browserAutomationIssues: [String: BrowserAutomationIssue] = [:]

    private let logger = Logger(subsystem: "com.soundtune.SoundTune", category: "AppMediaInfoService")
    private nonisolated static let scriptLogger = Logger(subsystem: "com.soundtune.SoundTune", category: "AppMediaInfoService.Script")

    // Separator constants.
    // fSep separates fields within a tab record (w-idx, t-idx, isFront, title, url, js-result).
    // rSep separates tab records from each other.
    // jPipe is produced by | inside the JS return; the last 3 tokens are state|pos|dur,
    //   everything before is title|artist|artworkURL (we parse from the right).
    private static let fSep = "\u{1c}"  // FS – tab record field sep
    private static let rSep = "\u{1e}"  // RS – tab record sep
    private static let jPipe = "|"      // JS sub-field sep (safe: state/pos/dur are fixed)
    private static let delim = "\u{01}\u{01}"  // used for music-app AppleScript returns
    private static let browserScriptErrorPrefix = "__SOUNDTUNE_BROWSER_JS_ERROR__"

    // Shared JS helper for pages with multiple media elements (notably YouTube Shorts).
    // Chooses an actively playing element first, then a visible element, then the most
    // progressed loaded element.
    private static let pickMediaElementJS =
        "function pickMediaElement(){" +
        "var els=Array.prototype.slice.call(document.querySelectorAll('video,audio'));" +
        "if(els.length===0)return null;" +
        "var scored=els.map(function(e){" +
        "var r=e.getBoundingClientRect?e.getBoundingClientRect():{width:0,height:0,top:0,left:0,bottom:0,right:0};" +
        "var visible=(r.width>1&&r.height>1&&r.bottom>0&&r.right>0&&r.top<window.innerHeight&&r.left<window.innerWidth)?1:0;" +
        "var playing=(!e.paused&&!e.ended&&e.readyState>0)?1:0;" +
        "var loaded=(e.readyState>0)?1:0;" +
        "return {e:e,s:(playing*1000)+(visible*100)+(loaded*10)+Math.min(9,Math.floor(e.currentTime||0))};" +
        "});" +
        "scored.sort(function(a,b){return b.s-a.s;});" +
        "return scored[0].e;" +
        "};"

    // Enhanced JS that reads Media Session API + <video>/<audio> element.
    // Returns: title|artist|artworkURL|state|pos|dur  (pipe-separated, 6 fields)
    // The pipe is safe here: state/pos/dur are predictable tokens; we use lastIndexOf to
    // find them from the right, so pipes in title/artist don't break parsing.
    // "none" is returned when there is no media to show.
    // Rules: single quotes only (no double-quote in JS body to avoid breaking AppleScript string arg).
    private static let mediaSessionJS: String =
        "(function(){try{" +
        pickMediaElementJS +
        "var ms=navigator.mediaSession;" +
        "var meta=ms?ms.metadata:null;" +
        "var ti=meta?(meta.title||''):'',ar=meta?(meta.artist||''):'';" +
        "var aw='';" +
        "if(meta&&meta.artwork&&meta.artwork.length>0){" +
        "var ax=meta.artwork,best=ax[ax.length-1];" +
        "aw=best?(best.src||''):'';" +
        "}" +
        "var clean=function(s){return String(s||'').split('|').join(' ');};" +
        "var loc=window.location,host=(loc.hostname||''),path=loc.pathname||'';" +
        "if(host.indexOf('www.')===0)host=host.slice(4);" +
        "var isYT=(host==='youtube.com'||host.endsWith('.youtube.com')||host==='youtu.be');" +
        "var ytPlayable=(path==='/watch'||path.indexOf('/shorts/')===0||path.indexOf('/live/')===0||path.indexOf('/embed/')===0);" +
        "var isNetflix=(host==='netflix.com'||host.endsWith('.netflix.com'));" +
        "var knownPlayable=(isYT&&ytPlayable)||(isNetflix&&path.indexOf('/watch')===0);" +
        "var v=pickMediaElement();" +
        "var hasElement=!!v;" +
        "var playing=!!(v&&!v.paused&&!v.ended);" +
        "if(isYT&&!ytPlayable&&!playing)return 'none';" +
        "if(isYT&&!ytPlayable&&v.muted)return 'none';" +
        "var pageTitle=document.title||'';" +
        "if(!hasElement&&ti===''&&!knownPlayable)return 'none';" +
        "var st=(ms&&ms.playbackState&&ms.playbackState!=='none')?ms.playbackState:'none';" +
        "if(hasElement)st=v.paused?'paused':'playing';" +
        "if(st==='none'&&knownPlayable)st='paused';" +
        "var pos=v?Math.floor(v.currentTime||0):0,dur=(v&&isFinite(v.duration))?Math.floor(v.duration||0):0;" +
        "if(st!=='playing'&&st!=='paused')return 'none';" +
        "if(ti==='')ti=pageTitle;" +
        "if(ti==='')ti=host;" +
        "return clean(ti)+'|'+clean(ar)+'|'+clean(aw)+'|'+st+'|'+pos+'|'+dur;" +
        "}catch(e){return 'none';}})()"

    private var targets: [(bundleID: String, kind: MediaAppKind)] = []
    private var activeAppTargets: [(bundleID: String, kind: MediaAppKind)] = []
    private var pollTask: Task<Void, Never>?
    private var isPolling = false
    private var pendingPlaybackBySourceID: [String: PendingPlayback] = [:]
    private var pendingSeekBySourceID: [String: PendingSeek] = [:]

    private var imageCache: [String: NSImage] = [:]
    private var artworkKeyBySourceID: [String: String] = [:]
    private var inFlightImageKeys: Set<String> = []

    private struct PendingPlayback {
        let isPlaying: Bool
        let createdAt: Date
    }

    private struct PendingSeek {
        let position: Double
        let wasPlaying: Bool
        let createdAt: Date
    }

    // MARK: - App recognition

    enum MediaAppKind {
        case chromiumBrowser
        case safari
        case spotify
        case appleMusic
        case vlc
    }

    enum BrowserAutomationIssue: Equatable {
        case automationPermissionDenied
        case javascriptFromAppleEventsDisabled
        case scriptFailed
    }

    static func kind(forBundleID id: String?) -> MediaAppKind? {
        guard let id else { return nil }
        switch id {
        case "com.google.Chrome", "com.google.Chrome.canary",
             "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
             "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
             "com.vivaldi.Vivaldi",
             "com.operasoftware.Opera", "com.operasoftware.OperaGX",
             "org.chromium.Chromium":
            return .chromiumBrowser
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return .safari
        case "com.spotify.client":
            return .spotify
        case "com.apple.Music":
            return .appleMusic
        case "org.videolan.vlc":
            return .vlc
        default:
            return nil
        }
    }

    private static let drmHosts: Set<String> = [
        "netflix.com", "primevideo.com", "disneyplus.com",
        "max.com", "hbomax.com", "hulu.com",
        "peacocktv.com", "paramountplus.com"
    ]

    static func isDRM(urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return drmHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func setActiveApps(_ apps: [AudioApp]) {
        var newActiveTargets: [(String, MediaAppKind)] = []
        var activeSeen: Set<String> = []
        for app in apps {
            guard let bundleID = app.bundleID, !activeSeen.contains(bundleID),
                  let kind = Self.kind(forBundleID: bundleID) else { continue }
            activeSeen.insert(bundleID)
            newActiveTargets.append((bundleID, kind))
        }

        activeAppTargets = newActiveTargets.map { (bundleID: $0.0, kind: $0.1) }
        rebuildTargetsFromRunningApps()

        let liveBundleIDs = Set(targets.map(\.bundleID))
        infoByBundleID = infoByBundleID.filter { liveBundleIDs.contains($0.key) }
        nowPlayingSources = nowPlayingSources.filter { liveBundleIDs.contains($0.appBundleID) }
        browserAutomationIssues = browserAutomationIssues.filter { liveBundleIDs.contains($0.key) }
        artworkKeyBySourceID = artworkKeyBySourceID.filter { (sourceID, _) in
            nowPlayingSources.contains(where: { $0.id == sourceID }) ||
            infoByBundleID.keys.contains(sourceID)
        }
        Task { @MainActor [weak self] in await self?.pollOnce() }
    }

    private func rebuildTargetsFromRunningApps() {
        var newTargets = activeAppTargets
        var seen = Set(newTargets.map(\.bundleID))

        // Running media-capable apps may be paused or missed by the audio process monitor.
        // Browser probes filter stale/home-page metadata, so polling running browsers keeps
        // paused tabs discoverable without keeping bogus YouTube home cards alive.
        for runningApp in NSWorkspace.shared.runningApplications {
            guard let bundleID = runningApp.bundleIdentifier,
                  !seen.contains(bundleID),
                  let kind = Self.kind(forBundleID: bundleID) else { continue }
            seen.insert(bundleID)
            newTargets.append((bundleID, kind))
        }

        targets = newTargets.map { (bundleID: $0.0, kind: $0.1) }
    }

    func info(forBundleID bundleID: String?) -> AppMediaInfo? {
        guard let bundleID else { return nil }
        return infoByBundleID[bundleID]
    }

    // MARK: - Transport (music apps only — browsers routed by caller via system commands or JS)

    func playPause(bundleID: String) { sendTransport(bundleID: bundleID, action: .playPause) }
    func next(bundleID: String) { sendTransport(bundleID: bundleID, action: .next) }
    func previous(bundleID: String) { sendTransport(bundleID: bundleID, action: .previous) }

    private enum TransportAction { case playPause, next, previous }

    private struct BrowserTabTarget {
        let bundleID: String
        let kind: MediaAppKind
        let windowIndex: Int
        let tabIndex: Int
        let expectedURL: String?
    }

    private func sendTransport(bundleID: String, action: TransportAction) {
        guard let kind = Self.kind(forBundleID: bundleID),
              let command = Self.transportCommand(kind: kind, action: action) else { return }
        // Optimistic play/pause flip for instant visual feedback
        if action == .playPause,
           let idx = nowPlayingSources.firstIndex(where: { $0.appBundleID == bundleID }) {
            nowPlayingSources[idx].isPlaying.toggle()
        }
        let script = "try\ntell application id \"\(bundleID)\" to \(command)\nend try"
        let needsSync = action != .playPause  // next/prev load a new track; play/pause is optimistic
        Task { @MainActor [weak self] in
            _ = await self?.runAppleScript(script)
            if needsSync { await self?.pollOnce() }
        }
    }

    private static func transportCommand(kind: MediaAppKind, action: TransportAction) -> String? {
        switch kind {
        case .spotify, .appleMusic:
            switch action {
            case .playPause: return "playpause"
            case .next:      return "next track"
            case .previous:  return "previous track"
            }
        case .vlc:
            switch action {
            case .playPause: return "play"
            case .next:      return "next"
            case .previous:  return "previous"
            }
        case .chromiumBrowser, .safari:
            return nil
        }
    }

    // MARK: - Seek

    /// Seeks only the music app or browser tab represented by this source.
    func seek(source: NowPlayingSource, to seconds: Double) {
        switch source.locator {
        case .musicApp(let bundleID):
            guard let kind = Self.kind(forBundleID: bundleID) else { return }
            switch kind {
            case .spotify, .appleMusic:
                let script = "tell application id \"\(bundleID)\" to set player position to \(seconds)"
                Task { @MainActor [weak self] in
                    _ = await self?.runAppleScript(script)
                    await self?.pollOnce()
                }
            default: break
            }

        case .browserFrontTab, .browserBackground:
            // Never inject `currentTime` into a DRM player. Netflix/Widevine reject the
            // assignment and Chrome raises AppleScript error m7375. DRM front tabs are seeked
            // via MediaRemote (see MenuBarPopupView.sourceSeek) and DRM background tabs are
            // non-seekable (canSeek = false), so this defensive bail-out simply guarantees no
            // JS seek ever reaches a DRM tab — even if this method is invoked directly.
            if let url = source.sourceURL, Self.isDRM(urlString: url) {
                seekOptimistically(source: source, to: seconds)
                return
            }
            guard let target = browserTabTarget(from: source) else { return }
            seekOptimistically(source: source, to: seconds)
            // Non-DRM tab: precise, per-tab JS seek wrapped in try/catch so a transient
            // exception can never propagate back to AppleScript.
            let js = "try{var v=pickMediaElement();if(v&&isFinite(v.duration))v.currentTime=\(Int(seconds));}catch(e){}"
            let script = browserJSScript(target: target, js: js)
            Task { @MainActor [weak self] in
                _ = await self?.runAppleScript(script)
                try? await Task.sleep(for: .milliseconds(250))
                await self?.pollOnce()
            }
        }
    }

    // Robust play/pause JS: tries v.play(), falls back to 'k' keyboard event (YouTube shortcut).
    // Single-quoted strings only — no double quotes to break AppleScript string arg.
    private static func setPlaybackJS(isPlaying: Bool) -> String {
        let action = isPlaying
            ? "var p=v.play();if(p)p.catch(function(){});"
            : "v.pause();"
        return "(function(){try{" +
        "var v=pickMediaElement();if(!v)return;" +
        action +
        "}catch(e){}})()"
    }

    /// play/pause for a browser tab via JS injection.
    /// Targets the tab represented by the card, not whichever tab happens to be front now.
    func playPauseBrowserTab(source: NowPlayingSource) {
        guard let target = browserTabTarget(from: source) else { return }
        let targetState = togglePlaybackOptimistically(for: source)
        let script = browserJSScript(target: target, js: Self.setPlaybackJS(isPlaying: targetState))
        Task { @MainActor [weak self] in
            _ = await self?.runAppleScript(script)
            try? await Task.sleep(for: .milliseconds(250))
            await self?.pollOnce()
        }
    }

    /// Compatibility wrapper for callers that already know the source is a background tab.
    func playPauseBrowserBackground(source: NowPlayingSource) {
        playPauseBrowserTab(source: source)
    }

    @discardableResult
    func togglePlaybackOptimistically(for source: NowPlayingSource) -> Bool {
        let currentState = nowPlayingSources.first(where: { $0.id == source.id })?.isPlaying
            ?? source.isPlaying
        let targetState = !currentState
        pendingPlaybackBySourceID[source.id] = PendingPlayback(
            isPlaying: targetState,
            createdAt: Date()
        )
        if let index = nowPlayingSources.firstIndex(where: { $0.id == source.id }) {
            nowPlayingSources[index].isPlaying = targetState
        }
        return targetState
    }

    func seekOptimistically(source: NowPlayingSource, to seconds: Double) {
        pendingSeekBySourceID[source.id] = PendingSeek(
            position: seconds,
            wasPlaying: source.isPlaying,
            createdAt: Date()
        )
        if let index = nowPlayingSources.firstIndex(where: { $0.id == source.id }) {
            nowPlayingSources[index].position = seconds
        }
    }

    private func browserTabTarget(from source: NowPlayingSource) -> BrowserTabTarget? {
        switch source.locator {
        case .browserFrontTab(bundleID: let bundleID, windowIndex: let winIndex, tabIndex: let tabIndex),
             .browserBackground(bundleID: let bundleID, windowIndex: let winIndex, tabIndex: let tabIndex):
            guard let kind = Self.kind(forBundleID: bundleID) else { return nil }
            return BrowserTabTarget(
                bundleID: bundleID,
                kind: kind,
                windowIndex: winIndex,
                tabIndex: tabIndex,
                expectedURL: source.sourceURL
            )
        case .musicApp:
            return nil
        }
    }

    private func browserJSScript(target: BrowserTabTarget, js: String) -> String {
        let escapedJS = Self.appleScriptStringLiteral(Self.pickMediaElementJS + js)
        let expectedURL = Self.appleScriptStringLiteral(target.expectedURL ?? "")
        let isChrome = target.kind == .chromiumBrowser
        if isChrome {
            return """
            try
            tell application id "\(target.bundleID)"
            set expectedURL to "\(expectedURL)"
            set targetTab to missing value
            if (count of windows) >= \(target.windowIndex) then
            set candidateWindow to window \(target.windowIndex)
            if (count of tabs of candidateWindow) >= \(target.tabIndex) then
            set candidateTab to tab \(target.tabIndex) of candidateWindow
            if expectedURL is "" or ((URL of candidateTab) as text) is expectedURL then set targetTab to candidateTab
            end if
            end if
            if targetTab is missing value and expectedURL is not "" then
            repeat with wi from 1 to (count of windows)
            set scanWindow to window wi
            repeat with ti from 1 to (count of tabs of scanWindow)
            set candidateTab to tab ti of scanWindow
            if ((URL of candidateTab) as text) is expectedURL then
            set targetTab to candidateTab
            exit repeat
            end if
            end repeat
            if targetTab is not missing value then exit repeat
            end repeat
            end if
            if targetTab is not missing value then execute targetTab javascript "\(escapedJS)"
            end tell
            end try
            """
        } else {
            return """
            try
            tell application id "\(target.bundleID)"
            set expectedURL to "\(expectedURL)"
            set targetTab to missing value
            if (count of windows) >= \(target.windowIndex) then
            set candidateWindow to window \(target.windowIndex)
            if (count of tabs of candidateWindow) >= \(target.tabIndex) then
            set candidateTab to tab \(target.tabIndex) of candidateWindow
            if expectedURL is "" or ((URL of candidateTab) as text) is expectedURL then set targetTab to candidateTab
            end if
            end if
            if targetTab is missing value and expectedURL is not "" then
            repeat with wi from 1 to (count of windows)
            set scanWindow to window wi
            repeat with ti from 1 to (count of tabs of scanWindow)
            set candidateTab to tab ti of scanWindow
            if ((URL of candidateTab) as text) is expectedURL then
            set targetTab to candidateTab
            exit repeat
            end if
            end repeat
            if targetTab is not missing value then exit repeat
            end repeat
            end if
            if targetTab is not missing value then do JavaScript "\(escapedJS)" in targetTab
            end tell
            end try
            """
        }
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Polling

    private func pollOnce() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        // Capture ordering NOW, before any awaits. setActiveApps can mutate
        // nowPlayingSources during async AppleScript calls; capturing here ensures
        // the final sort uses the pre-poll stable order.
        let existingIDs = nowPlayingSources.map { $0.id }

        rebuildTargetsFromRunningApps()
        let snapshot = targets
        logger.debug("Polling media targets: \(snapshot.map(\.bundleID).joined(separator: ","), privacy: .public)")
        var newSources: [NowPlayingSource] = []
        var newInfoMap: [String: AppMediaInfo] = [:]

        for target in snapshot {
            let bundleID = target.bundleID
            switch target.kind {
            case .chromiumBrowser, .safari:
                let sources = await pollBrowser(bundleID: bundleID, kind: target.kind)
                newSources.append(contentsOf: sources)
                // front-tab AppMediaInfo for row indicator
                if let front = sources.first(where: {
                    if case .browserFrontTab = $0.locator { return true }
                    return false
                }) ?? sources.first {
                    newInfoMap[bundleID] = AppMediaInfo(
                        title: front.title,
                        source: front.subtitle,
                        isPlaying: front.isPlaying,
                        supportsTransport: front.canTransport,
                        artwork: front.artwork,
                        position: front.position,
                        duration: front.duration
                    )
                }

            case .spotify, .appleMusic, .vlc:
                if let source = await pollMusicApp(bundleID: bundleID, kind: target.kind) {
                    newSources.append(source)
                    newInfoMap[bundleID] = AppMediaInfo(
                        title: source.title,
                        source: source.subtitle,
                        isPlaying: source.isPlaying,
                        supportsTransport: source.canTransport,
                        artwork: source.artwork,
                        position: source.position,
                        duration: source.duration
                    )
                }
            }
        }

        // Preserve existing card order; new sources append at end in stable ID order.
        var stabilizedSources = newSources
        applyPendingInteractions(to: &stabilizedSources)
        nowPlayingSources = stabilizedSources.sorted { a, b in
            let ai = existingIDs.firstIndex(of: a.id) ?? Int.max
            let bi = existingIDs.firstIndex(of: b.id) ?? Int.max
            if ai != bi { return ai < bi }
            return a.id < b.id
        }
        infoByBundleID = newInfoMap
        logger.debug("Media poll completed with \(self.nowPlayingSources.count, privacy: .public) source(s)")
    }

    private func applyPendingInteractions(to sources: inout [NowPlayingSource]) {
        let now = Date()

        for index in sources.indices {
            let sourceID = sources[index].id

            if let pending = pendingPlaybackBySourceID[sourceID] {
                let age = now.timeIntervalSince(pending.createdAt)
                if sources[index].isPlaying == pending.isPlaying, age > 0.2 {
                    pendingPlaybackBySourceID.removeValue(forKey: sourceID)
                } else if age < 3 {
                    sources[index].isPlaying = pending.isPlaying
                } else {
                    pendingPlaybackBySourceID.removeValue(forKey: sourceID)
                }
            }

            if let pending = pendingSeekBySourceID[sourceID] {
                let age = now.timeIntervalSince(pending.createdAt)
                let expected = pending.position + (pending.wasPlaying ? age : 0)
                if abs(sources[index].position - expected) < 2, age > 0.2 {
                    pendingSeekBySourceID.removeValue(forKey: sourceID)
                } else if age < 4 {
                    sources[index].position = min(sources[index].duration, expected)
                } else {
                    pendingSeekBySourceID.removeValue(forKey: sourceID)
                }
            }
        }

        let liveIDs = Set(sources.map(\.id))
        pendingPlaybackBySourceID = pendingPlaybackBySourceID.filter { liveIDs.contains($0.key) }
        pendingSeekBySourceID = pendingSeekBySourceID.filter { liveIDs.contains($0.key) }
    }

    // MARK: - Browser polling (all tabs)

    private func pollBrowser(bundleID: String, kind: MediaAppKind) async -> [NowPlayingSource] {
        let scriptResult = await runAppleScriptDetailed(
            allTabsScript(kind: kind, bundleID: bundleID),
            label: "browser tabs \(bundleID)"
        )
        guard let raw = scriptResult.value else {
            registerBrowserIssue(for: bundleID, from: scriptResult.errorNumber, message: scriptResult.errorMessage)
            return []
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(Self.browserScriptErrorPrefix) {
            let payload = String(trimmed.dropFirst(Self.browserScriptErrorPrefix.count))
            let fields = payload.components(separatedBy: Self.fSep)
            let errorNumber = fields.first.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let message = fields.dropFirst().joined(separator: Self.fSep)
            registerBrowserIssue(for: bundleID, from: errorNumber, message: message)
            return []
        }

        let sources = parseBrowserTabs(raw: raw, bundleID: bundleID, kind: kind)
        browserAutomationIssues.removeValue(forKey: bundleID)
        logger.debug("Browser \(bundleID, privacy: .public) returned \(sources.count, privacy: .public) source(s)")
        return sources
    }

    private func registerBrowserIssue(for bundleID: String, from errorNumber: Int?, message: String?) {
        let lowerMessage = message?.lowercased() ?? ""
        let issue: BrowserAutomationIssue
        if errorNumber == -1743 {
            issue = .automationPermissionDenied
        } else if lowerMessage.contains("javascript") {
            issue = .javascriptFromAppleEventsDisabled
        } else if lowerMessage.contains("not authorized") || lowerMessage.contains("not allowed") {
            issue = .automationPermissionDenied
        } else {
            issue = .scriptFailed
        }
        browserAutomationIssues[bundleID] = issue
        logger.debug(
            "Browser \(bundleID, privacy: .public) media probe issue: \(String(describing: issue), privacy: .public), error=\(errorNumber ?? 0, privacy: .public), message=\(message ?? "", privacy: .public)"
        )
    }

    private func parseBrowserTabs(raw: String, bundleID: String, kind: MediaAppKind) -> [NowPlayingSource] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let records = trimmed.components(separatedBy: Self.rSep)
        var sources: [NowPlayingSource] = []

        for record in records {
            let record = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !record.isEmpty else { continue }
            let fields = record.components(separatedBy: Self.fSep)
            // fields: [winIdx, tabIdx, isFront, tabTitle, tabURL, jsResult]
            guard fields.count >= 6 else { continue }
            let winIdx    = Int(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
            let tabIdx    = Int(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
            let isFront   = fields[2].trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            let tabTitle  = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let tabURL    = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let jsResult  = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)

            guard jsResult != "none", !jsResult.isEmpty else { continue }

            // Parse JS result: title|artist|artworkURL|state|pos|dur
            // Parse from the right so pipes in title/artist don't confuse parsing.
            let jsFields = jsResult.components(separatedBy: Self.jPipe)
            guard jsFields.count >= 4 else { continue }
            let dur      = Double(jsFields[jsFields.count - 1]) ?? 0
            let pos      = Double(jsFields[jsFields.count - 2]) ?? 0
            let state    = jsFields[jsFields.count - 3].lowercased()
            let msArtURL = jsFields.count > 3 ? jsFields[jsFields.count - 4] : ""
            let msArtist = jsFields.count > 4 ? jsFields[jsFields.count - 5] : ""
            let msTitle  = jsFields.count > 5 ? jsFields[0..<(jsFields.count - 5)].joined(separator: "|") : (jsFields.count > 0 ? jsFields[0] : "")

            guard state == "playing" || state == "paused" else { continue }

            let title   = msTitle.isEmpty ? tabTitle : msTitle
            guard !title.isEmpty else { continue }

            let host    = Self.host(from: tabURL)
            let subtitle = msArtist.isEmpty ? host : msArtist
            let locator: NowPlayingSource.Locator = isFront
                ? .browserFrontTab(bundleID: bundleID, windowIndex: winIdx, tabIndex: tabIdx)
                : .browserBackground(bundleID: bundleID, windowIndex: winIdx, tabIndex: tabIdx)

            let baseSourceID = Self.browserSourceID(
                bundleID: bundleID,
                urlString: tabURL,
                windowIndex: winIdx,
                tabIndex: tabIdx
            )
            let sourceID = Self.uniqueSourceID(baseSourceID, existing: sources.map(\.id))

            // Artwork: prefer Media Session artwork URL, fall back to favicon
            let artKey: String?
            let artURL: String?
            if !msArtURL.isEmpty {
                artKey = "ms-art:\(msArtURL)"
                artURL = msArtURL
            } else {
                artKey = host.isEmpty ? nil : "favicon:\(host)"
                artURL = nil
            }

            let art = artKey.flatMap { resolveArtwork(key: $0, sourceID: sourceID, browserHost: artURL == nil ? host : nil, directURL: artURL) }
            if let k = artKey { artworkKeyBySourceID[sourceID] = k }

            sources.append(NowPlayingSource(
                id: sourceID,
                kind: .browserTab,
                title: title,
                subtitle: subtitle,
                artwork: art,
                isPlaying: state == "playing",
                position: pos,
                duration: dur,
                canTransport: true,
                canSkip: false,
                canSeek: dur > 0,
                locator: locator,
                appBundleID: bundleID,
                sourceURL: tabURL
            ))
        }
        return sources
    }

    private static func browserSourceID(bundleID: String, urlString: String, windowIndex: Int, tabIndex: Int) -> String {
        if !urlString.isEmpty {
            return "\(bundleID):url:\(urlString)"
        }
        return "\(bundleID):tab:\(windowIndex):\(tabIndex)"
    }

    private static func uniqueSourceID(_ baseID: String, existing: [String]) -> String {
        guard existing.contains(baseID) else { return baseID }
        var suffix = 2
        var candidate = "\(baseID)#\(suffix)"
        while existing.contains(candidate) {
            suffix += 1
            candidate = "\(baseID)#\(suffix)"
        }
        return candidate
    }

    // MARK: - Music app polling

    private func pollMusicApp(bundleID: String, kind: MediaAppKind) async -> NowPlayingSource? {
        let d = Self.delim
        guard let raw = await runAppleScript(musicAppScript(kind: kind, bundleID: bundleID, delim: d)),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let fields = raw.components(separatedBy: d)
        guard fields.count >= 4 else { return nil }
        let title  = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let artURL = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let state  = fields[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty else { return nil }
        let pos    = fields.count > 4 ? Self.parseAppleScriptNumber(fields[4]) : 0
        let dur    = fields.count > 5 ? Self.parseAppleScriptNumber(fields[5]) : 0
        let isPlaying = state == "playing" || state == "true"

        let artKey = artURL.isEmpty ? nil : "art:\(artURL)"
        let art = artKey.flatMap { resolveArtwork(key: $0, sourceID: bundleID, browserHost: nil, directURL: artURL.isEmpty ? nil : artURL) }
        if let k = artKey { artworkKeyBySourceID[bundleID] = k }

        let canSeek = (kind == .spotify || kind == .appleMusic) && dur > 0
        return NowPlayingSource(
            id: bundleID,
            kind: .musicApp,
            title: title,
            subtitle: artist,
            artwork: art,
            isPlaying: isPlaying,
            position: pos,
            duration: dur,
            canTransport: true,
            canSkip: true,
            canSeek: canSeek,
            locator: .musicApp(bundleID: bundleID),
            appBundleID: bundleID,
            sourceURL: nil
        )
    }

    // MARK: - Artwork

    private static func parseAppleScriptNumber(_ value: String) -> Double {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(normalized) ?? 0
    }

    private func resolveArtwork(key: String, sourceID: String, browserHost: String?, directURL: String?) -> NSImage? {
        guard !key.isEmpty else { return nil }
        if let cached = imageCache[key] { return cached }
        guard !inFlightImageKeys.contains(key) else { return nil }

        let urlString: String?
        if let host = browserHost, !host.isEmpty {
            urlString = "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
        } else {
            urlString = directURL
        }
        guard let urlString, let url = URL(string: urlString) else { return nil }

        inFlightImageKeys.insert(key)
        Task { @MainActor [weak self] in
            let data = await Self.downloadData(url)
            guard let self else { return }
            self.inFlightImageKeys.remove(key)
            guard let data, let image = NSImage(data: data) else { return }
            self.imageCache[key] = image
            self.applyArtwork(forKey: key, image: image)
        }
        return nil
    }

    private func applyArtwork(forKey key: String, image: NSImage) {
        // Update nowPlayingSources
        for i in nowPlayingSources.indices {
            if artworkKeyBySourceID[nowPlayingSources[i].id] == key,
               nowPlayingSources[i].artwork !== image {
                nowPlayingSources[i].artwork = image
            }
        }
        // Update infoByBundleID
        for (bundleID, wantedKey) in artworkKeyBySourceID where wantedKey == key {
            if var info = infoByBundleID[bundleID], info.artwork !== image {
                info.artwork = image
                infoByBundleID[bundleID] = info
            }
        }
    }

    private nonisolated static func downloadData(_ url: URL) async -> Data? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        } catch {
            return nil
        }
    }

    private static func host(from urlString: String) -> String {
        guard let host = URL(string: urlString)?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - AppleScript execution

    private nonisolated static let scriptQueue = DispatchQueue(label: "com.soundtune.applescript", qos: .userInitiated)
    // Compiled NSAppleScript instances are reusable; caching avoids recompilation on every call.
    // Accessed only from scriptQueue (serial), so no additional locking is needed.
    // nonisolated(unsafe): accessed only from the serial scriptQueue — manually thread-safe.
    private nonisolated(unsafe) static let scriptCache = NSCache<NSString, NSAppleScript>()

    private struct ScriptExecutionResult: Sendable {
        let value: String?
        let errorNumber: Int?
        let errorMessage: String?
    }

    private nonisolated func runAppleScript(_ source: String) async -> String? {
        await runAppleScriptDetailed(source, label: "AppleScript").value
    }

    private nonisolated func runAppleScriptDetailed(_ source: String, label: String) async -> ScriptExecutionResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ScriptExecutionResult, Never>) in
            Self.scriptQueue.async {
                let key = source as NSString
                let script: NSAppleScript
                if let cached = Self.scriptCache.object(forKey: key) {
                    script = cached
                } else {
                    guard let newScript = NSAppleScript(source: source) else {
                        Self.scriptLogger.debug("Failed to compile \(label, privacy: .public)")
                        cont.resume(returning: ScriptExecutionResult(value: nil, errorNumber: nil, errorMessage: "compile failed")); return
                    }
                    Self.scriptCache.setObject(newScript, forKey: key)
                    script = newScript
                }
                var error: NSDictionary?
                let descriptor = script.executeAndReturnError(&error)
                if let error {
                    let number = error[NSAppleScript.errorNumber] as? Int
                    let message = error[NSAppleScript.errorMessage] as? String
                    Self.scriptLogger.debug(
                        "\(label, privacy: .public) failed: number=\(number ?? 0, privacy: .public), message=\(message ?? "", privacy: .public)"
                    )
                    cont.resume(returning: ScriptExecutionResult(value: nil, errorNumber: number, errorMessage: message))
                } else {
                    cont.resume(returning: ScriptExecutionResult(value: descriptor.stringValue, errorNumber: nil, errorMessage: nil))
                }
            }
        }
    }

    // MARK: - AppleScript generation

    private func allTabsScript(kind: MediaAppKind, bundleID: String) -> String {
        let fSep = Self.fSep
        let rSep = Self.rSep
        let js = Self.mediaSessionJS
        let errorPrefix = Self.browserScriptErrorPrefix
        let maxTabs = 25   // max tabs to JS-probe per browser invocation

        switch kind {
        case .chromiumBrowser:
            return """
            try
            tell application id "\(bundleID)"
            if (count of windows) is 0 then return ""
            set fS to "\(fSep)"
            set rS to "\(rSep)"
            set outStr to ""
            set scanned to 0
            set firstJSError to ""
            set frontTab to active tab of window 1
            repeat with wi from 1 to (count of windows)
            set theWindow to window wi
            repeat with ti from 1 to (count of tabs of theWindow)
            if scanned >= \(maxTabs) then exit repeat
            set theTab to tab ti of theWindow
            set u to URL of theTab
            if u is not missing value and (u does not start with "chrome://") and (u does not start with "about:") and u is not "" then
            set tt to title of theTab
            set isFront to "0"
            if wi is 1 then
            try
            if theTab is frontTab then set isFront to "1"
            end try
            end if
            set s to "none"
            try
            set s to (execute theTab javascript "\(js)")
            if s is missing value then set s to "none"
            on error errMsg number errNum
            if firstJSError is "" then set firstJSError to (errNum as text) & fS & errMsg
            set s to "none"
            end try
            if s is not "none" then
            set outStr to outStr & wi & fS & ti & fS & isFront & fS & tt & fS & u & fS & s & rS
            end if
            set scanned to scanned + 1
            end if
            end repeat
            end repeat
            if outStr is "" and firstJSError is not "" then return "\(errorPrefix)" & firstJSError
            return outStr
            end tell
            end try
            return ""
            """

        case .safari:
            return """
            try
            tell application id "\(bundleID)"
            if (count of windows) is 0 then return ""
            set fS to "\(fSep)"
            set rS to "\(rSep)"
            set outStr to ""
            set scanned to 0
            set firstJSError to ""
            set frontTab to current tab of window 1
            repeat with wi from 1 to (count of windows)
            set theWindow to window wi
            try
            set tabList to tabs of theWindow
            repeat with ti from 1 to (count of tabList)
            if scanned >= \(maxTabs) then exit repeat
            set theTab to item ti of tabList
            set u to URL of theTab
            if u is not missing value and (u does not start with "about:") and u is not "" then
            set tt to name of theTab
            set isFront to "0"
            if wi is 1 then
            try
            if theTab is frontTab then set isFront to "1"
            end try
            end if
            set s to "none"
            try
            set s to (do JavaScript "\(js)" in theTab)
            if s is missing value then set s to "none"
            on error errMsg number errNum
            if firstJSError is "" then set firstJSError to (errNum as text) & fS & errMsg
            set s to "none"
            end try
            if s is not "none" then
            set outStr to outStr & wi & fS & ti & fS & isFront & fS & tt & fS & u & fS & s & rS
            end if
            set scanned to scanned + 1
            end if
            end repeat
            end try
            end repeat
            if outStr is "" and firstJSError is not "" then return "\(errorPrefix)" & firstJSError
            return outStr
            end tell
            end try
            return ""
            """

        default:
            return ""
        }
    }

    private func musicAppScript(kind: MediaAppKind, bundleID: String, delim: String) -> String {
        let d = delim
        switch kind {
        case .spotify:
            return """
            try
            tell application id "\(bundleID)"
            if player state is stopped then return ""
            set t to name of current track
            set a to artist of current track
            set u to artwork url of current track
            set s to player state as text
            set pp to player position
            set dd to (duration of current track) / 1000
            return t & "\(d)" & a & "\(d)" & u & "\(d)" & s & "\(d)" & pp & "\(d)" & dd
            end tell
            end try
            return ""
            """
        case .appleMusic:
            return """
            try
            tell application id "\(bundleID)"
            if player state is stopped then return ""
            set t to name of current track
            set a to artist of current track
            set s to player state as text
            set pp to player position
            set dd to duration of current track
            return t & "\(d)" & a & "\(d)" & "" & "\(d)" & s & "\(d)" & pp & "\(d)" & dd
            end tell
            end try
            return ""
            """
        case .vlc:
            return """
            try
            tell application id "\(bundleID)"
            set t to name of current item
            set s to (playing as text)
            return t & "\(d)" & "" & "\(d)" & "" & "\(d)" & s
            end tell
            end try
            return ""
            """
        default:
            return ""
        }
    }
}
