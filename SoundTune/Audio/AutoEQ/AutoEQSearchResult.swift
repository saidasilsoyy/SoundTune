// SoundTune/Audio/AutoEQ/AutoEQSearchResult.swift
import Foundation

/// Search result from `AutoEQProfileManager.search()`.
struct AutoEQSearchResult {
    let entries: [AutoEQCatalogEntry]
    let totalCount: Int
}
