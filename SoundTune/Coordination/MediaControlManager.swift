// SoundTune/Coordination/MediaControlManager.swift
import Foundation
import AppKit

// MARK: - MRMediaRemote Bridge

private final class MRBridge: @unchecked Sendable {
    private let pGetInfo: UnsafeMutableRawPointer
    private let pGetPID:  UnsafeMutableRawPointer
    private let pSendCmd: UnsafeMutableRawPointer
    private let pSetTime: UnsafeMutableRawPointer

    static func load() -> MRBridge? {
        guard let h = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW
        ),
        let p1 = dlsym(h, "MRMediaRemoteGetNowPlayingInfo"),
        let p2 = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID"),
        let p3 = dlsym(h, "MRMediaRemoteSendCommand"),
        let p4 = dlsym(h, "MRMediaRemoteSetElapsedTime")
        else { return nil }
        return MRBridge(pGetInfo: p1, pGetPID: p2, pSendCmd: p3, pSetTime: p4)
    }

    private init(pGetInfo: UnsafeMutableRawPointer, pGetPID: UnsafeMutableRawPointer,
                 pSendCmd: UnsafeMutableRawPointer, pSetTime: UnsafeMutableRawPointer) {
        self.pGetInfo = pGetInfo; self.pGetPID = pGetPID
        self.pSendCmd = pSendCmd; self.pSetTime = pSetTime
    }

    func getNowPlayingInfo(queue: DispatchQueue, completion: @escaping ([String: Any]?) -> Void) {
        typealias Fn = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
        unsafeBitCast(pGetInfo, to: Fn.self)(queue, completion)
    }

    func getNowPlayingApp(queue: DispatchQueue, completion: @escaping (String, String) -> Void) {
        typealias Fn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
        unsafeBitCast(pGetPID, to: Fn.self)(queue) { pid in
            guard pid > 0,
                  let app = NSRunningApplication(processIdentifier: pid_t(pid))
            else { completion("", ""); return }
            completion(app.localizedName ?? "", app.bundleIdentifier ?? "")
        }
    }

    @discardableResult
    func sendCommand(_ cmd: Int32) -> Bool {
        typealias Fn = @convention(c) (Int32, CFDictionary?) -> Bool
        return unsafeBitCast(pSendCmd, to: Fn.self)(cmd, nil)
    }

    func setElapsedTime(_ seconds: Double) {
        typealias Fn = @convention(c) (Double) -> Void
        unsafeBitCast(pSetTime, to: Fn.self)(seconds)
    }
}

// MRMediaRemoteSendCommand constants
private enum MRCmd {
    static let play: Int32  = 0
    static let pause: Int32 = 1
    static let toggle: Int32 = 2
    static let next: Int32  = 4
    static let prev: Int32  = 5
}

// MRMediaRemoteNowPlayingInfo keys
private enum MRKey {
    static let title    = "kMRMediaRemoteNowPlayingInfoTitle"
    static let artist   = "kMRMediaRemoteNowPlayingInfoArtist"
    static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
    static let elapsed  = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let rate     = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    static let artwork  = "kMRMediaRemoteNowPlayingInfoArtworkData"
}

// MARK: - Result

private struct MCMRefreshResult: Sendable {
    var appName: String
    var appBundleID: String
    var title: String
    var artist: String
    var isPlaying: Bool
    var duration: Double
    var position: Double
    var artworkData: Data?
    var artworkKey: String
    var hasNewArtwork: Bool
    var hasMedia: Bool

    static func empty() -> MCMRefreshResult {
        MCMRefreshResult(appName: "", appBundleID: "", title: "", artist: "", isPlaying: false,
                         duration: 0, position: 0, artworkData: nil,
                         artworkKey: "", hasNewArtwork: false, hasMedia: false)
    }
}


// Shared mutable gather box — @unchecked Sendable because DispatchGroup provides ordering
private final class MRGatherBox: @unchecked Sendable {
    var info: [String: Any]?
    var appName: String?
    var appBundleID: String?
}

// MARK: - Manager

@Observable
@MainActor
final class MediaControlManager {

    // MARK: - Published Properties
    var title: String = "Not Playing"
    var artist: String = ""
    var isPlaying: Bool = false
    var position: Double = 0
    var duration: Double = 0
    var appName: String = ""
    var appBundleID: String = ""
    var artwork: NSImage? = nil

    // MARK: - Private
    private var timer: Timer?
    private let mrBridge: MRBridge?
    private var artworkCacheKey: String = ""

    init() {
        mrBridge = MRBridge.load()
    }

    // MARK: - Lifecycle
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        scheduleRefresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        scheduleRefresh()
    }

    // MARK: - Controls
    func playPause() {
        mrBridge?.sendCommand(MRCmd.toggle)
        scheduleRefresh()
    }

    func next() {
        mrBridge?.sendCommand(MRCmd.next)
        scheduleRefresh()
    }

    func previous() {
        mrBridge?.sendCommand(MRCmd.prev)
        scheduleRefresh()
    }

    func seek(to seconds: Double) {
        position = seconds
        mrBridge?.setElapsedTime(seconds)
    }

    // MARK: - Private: Scheduling

    private func scheduleRefresh() {
        guard let bridge = mrBridge else { clearState(); return }
        let cacheKey = artworkCacheKey

        // Task.detached is explicitly NON-ISOLATED — Swift never infers @MainActor
        // for its closure, avoiding the runtime dispatch_assert_queue crash on macOS 26.
        // MRGatherBox is @unchecked Sendable so it can cross boundaries safely.
        // group.notify closure only resumes a Void continuation (Void is Sendable).
        let box = MRGatherBox()
        let group = DispatchGroup()

        group.enter()
        bridge.getNowPlayingInfo(queue: .global()) { info in
            box.info = info
            group.leave()
        }
        group.enter()
        bridge.getNowPlayingApp(queue: .global()) { name, bundleID in
            box.appName = name
            box.appBundleID = bundleID
            group.leave()
        }

        Task.detached(priority: .utility) { [weak self] in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global()) { cont.resume() }
            }
            let result = MediaControlManager.buildResult(from: box, cachedKey: cacheKey)
            await MainActor.run { self?.applyState(result) }
        }
    }

    // MARK: - Private: Build result (static nonisolated — safe to call from any context)

    private static nonisolated func buildResult(from box: MRGatherBox, cachedKey: String) -> MCMRefreshResult {
        guard let info = box.info, !info.isEmpty,
              let title = info[MRKey.title] as? String, !title.isEmpty
        else { return .empty() }

        let artist   = info[MRKey.artist] as? String ?? ""
        let duration = (info[MRKey.duration] as? NSNumber)?.doubleValue ?? 0
        let elapsed  = (info[MRKey.elapsed] as? NSNumber)?.doubleValue ?? 0
        let rate     = (info[MRKey.rate] as? NSNumber)?.doubleValue ?? 0
        let appName  = box.appName ?? ""
        let appBundleID = box.appBundleID ?? ""

        let newKey         = "\(appName)|\(title)"
        let artworkChanged = newKey != cachedKey
        let artworkData    = artworkChanged ? (info[MRKey.artwork] as? Data) : nil

        return MCMRefreshResult(
            appName: appName, appBundleID: appBundleID, title: title, artist: artist,
            isPlaying: rate > 0, duration: duration, position: elapsed,
            artworkData: artworkData, artworkKey: newKey,
            hasNewArtwork: artworkChanged, hasMedia: true
        )
    }

    // MARK: - Private: State Application

    private func applyState(_ state: MCMRefreshResult) {
        if state.hasMedia {
            appName   = state.appName
            appBundleID = state.appBundleID
            title     = state.title
            artist    = state.artist
            isPlaying = state.isPlaying
            duration  = state.duration
            position  = state.position
            artworkCacheKey = state.artworkKey
            if state.hasNewArtwork {
                artwork = state.artworkData.flatMap { NSImage(data: $0) }
            }
        } else {
            clearState()
        }
    }

    private func clearState() {
        title = "Not Playing"; artist = ""; isPlaying = false
        position = 0; duration = 0; appName = ""; appBundleID = ""; artwork = nil
        artworkCacheKey = ""
    }
}
