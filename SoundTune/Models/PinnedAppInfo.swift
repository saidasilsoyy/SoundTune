// SoundTune/Models/PinnedAppInfo.swift
import Foundation

/// Identifies an app that has been pinned to remain visible in the popup when inactive.
struct PinnedAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

/// Identifies an app that has been ignored/hidden from the popup.
struct IgnoredAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}
