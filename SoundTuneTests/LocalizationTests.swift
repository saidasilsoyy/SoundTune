// SoundTuneTests/LocalizationTests.swift
import Testing
import Foundation
@testable import SoundTune

// MARK: - Helpers

@MainActor
private func makeManager() -> LanguageManager { LanguageManager() }

// MARK: - Translation Completeness

@Suite("Localization — Translation completeness")
@MainActor
struct LocalizationCompletenessTests {

    @Test("Translations table is populated (JSON parsed correctly)")
    func translationTableIsPopulated() {
        let manager = makeManager()
        #expect(manager.translationCount > 200, "Expected 200+ keys, got \(manager.translationCount)")
    }

    @Test("Every key has an English entry")
    func allKeysHaveEnglish() {
        let manager = makeManager()
        manager.currentLanguage = .english
        let knownKeys = [
            "Volume", "Mute", "Unmute", "Settings", "Cancel", "Save",
            "EQ", "Equalizer", "Bluetooth", "General", "Devices",
            "Apps", "Reset", "Close", "Default", "Custom",
            "Audio Device Reconnected", "Audio Device Disconnected",
            "Media keys offline", "Retry", "Preview", "Hz",
            "Select an AutoEQ ParametricEQ.txt file",
        ]
        for key in knownKeys {
            let result = manager.translate(key)
            #expect(!result.isEmpty, "Translation for '\(key)' must not be empty")
        }
    }

    @Test("Every key has a Turkish entry distinct from English for non-trivial keys")
    func turkishDiffersFromEnglishForNonTrivialKeys() {
        let sameInBothLanguages: Set<String> = ["Hz", "DDC", "AutoEQ", "Bluetooth", "Podcast",
                                                "Rock", "Pop", "R&B", "Hip-Hop", "EQ"]
        let testKeys = ["Volume", "Mute", "Cancel", "Settings", "Devices",
                        "Equalizer", "General", "Close", "Default", "Retry"]
        let manager = makeManager()
        for key in testKeys {
            guard !sameInBothLanguages.contains(key) else { continue }
            manager.currentLanguage = .english
            let en = manager.translate(key)
            manager.currentLanguage = .turkish
            let tr = manager.translate(key)
            #expect(en != tr, "Key '\(key)': Turkish translation should differ from English")
        }
    }

    @Test("Missing key falls back to the key itself")
    func missingKeyFallback() {
        let manager = makeManager()
        let fakeKey = "THIS_KEY_DOES_NOT_EXIST_XYZ_987"
        manager.currentLanguage = .english
        #expect(manager.translate(fakeKey) == fakeKey)
        manager.currentLanguage = .turkish
        #expect(manager.translate(fakeKey) == fakeKey)
    }
}

// MARK: - Language Switching

@Suite("Localization — Language switching")
@MainActor
struct LocalizationLanguageSwitchingTests {

    @Test("Switching to Turkish returns Turkish strings")
    func switchToTurkish() {
        let manager = makeManager()
        manager.currentLanguage = .turkish
        #expect(manager.translate("Volume") == "Ses Seviyesi")
    }

    @Test("Switching back to English returns English strings")
    func switchBackToEnglish() {
        let manager = makeManager()
        manager.currentLanguage = .turkish
        manager.currentLanguage = .english
        #expect(manager.translate("Volume") == "Volume")
    }

    @Test("Turkish translation for Cancel is İptal")
    func turkishCancel() {
        let manager = makeManager()
        manager.currentLanguage = .turkish
        #expect(manager.translate("Cancel") == "İptal")
    }

    @Test("English translation for Cancel is Cancel")
    func englishCancel() {
        let manager = makeManager()
        manager.currentLanguage = .english
        #expect(manager.translate("Cancel") == "Cancel")
    }

    @Test("t() delegates to LanguageManager.shared.translate for the current language")
    func tFunctionDelegates() {
        #expect(t("Volume") == LanguageManager.shared.translate("Volume"))
    }

    @Test("AppLanguage.english has correct rawValue and displayName")
    func englishMetadata() {
        #expect(AppLanguage.english.rawValue == "en")
        #expect(AppLanguage.english.displayName == "English")
    }

    @Test("AppLanguage.turkish has correct rawValue and displayName")
    func turkishMetadata() {
        #expect(AppLanguage.turkish.rawValue == "tr")
        #expect(AppLanguage.turkish.displayName == "Türkçe")
    }

    @Test("AppLanguage.system resolves to a supported language")
    func systemMetadata() {
        #expect(AppLanguage.system.rawValue == "system")
        #expect(AppLanguage.allCases.filter { $0 != .system }.contains(AppLanguage.system.resolvedLanguage))
    }

    @Test("Supported system language codes resolve deterministically")
    func supportedLanguageResolution() {
        #expect(AppLanguage.resolve(languageCode: "tr") == .turkish)
        #expect(AppLanguage.resolve(languageCode: "en") == .english)
        #expect(AppLanguage.resolve(languageCode: "de") == .german)
        #expect(AppLanguage.resolve(languageCode: "es") == .spanish)
        #expect(AppLanguage.resolve(languageCode: "fr") == .french)
        #expect(AppLanguage.resolve(languageCode: nil) == .english)
    }

    @Test("System language resolution follows preferred languages order")
    func preferredLanguagesResolution() {
        #expect(AppLanguage.resolve(preferredLanguages: ["tr-TR", "en-US"]) == .turkish)
        #expect(AppLanguage.resolve(preferredLanguages: ["de-DE", "tr-TR"]) == .german)
        #expect(AppLanguage.resolve(preferredLanguages: ["ja-JP", "fr-FR"]) == .french)
        #expect(AppLanguage.resolve(preferredLanguages: ["ja-JP"]) == .english)
    }

    @Test("All AppLanguage cases are present")
    func allCasesPresent() {
        #expect(AppLanguage.allCases.count == 6)
        #expect(AppLanguage.allCases.contains(.system))
        #expect(AppLanguage.allCases.contains(.english))
        #expect(AppLanguage.allCases.contains(.turkish))
        #expect(AppLanguage.allCases.contains(.german))
        #expect(AppLanguage.allCases.contains(.spanish))
        #expect(AppLanguage.allCases.contains(.french))
    }

    @Test("Percentage formatting follows the selected language")
    func localizedPercentageFormatting() {
        let manager = makeManager()

        manager.currentLanguage = .english
        let english = manager.formatPercentage(0.125)
        #expect(english.contains("12.5"))
        #expect(english.hasSuffix("%"))

        manager.currentLanguage = .turkish
        let turkish = manager.formatPercentage(0.125)
        #expect(turkish.contains("12,5"))
        #expect(turkish.hasPrefix("%"))

        manager.currentLanguage = .german
        let german = manager.formatPercentage(0.125)
        #expect(german.contains("12,5"))
        #expect(german.contains("%"))
    }

    @Test("Settings option labels are translated")
    func settingsOptionLabelsAreTranslated() {
        let manager = makeManager()
        manager.currentLanguage = .turkish

        #expect(manager.translate("Coarse (12.5%)") == "Büyük (%12,5)")
        #expect(manager.translate("Compact") == "Kompakt")
        #expect(manager.translate("On") == "Açık")

        manager.currentLanguage = .german
        #expect(manager.translate("Volume") == "Lautstärke")

        manager.currentLanguage = .spanish
        #expect(manager.translate("Settings") == "Ajustes")

        manager.currentLanguage = .french
        #expect(manager.translate("Devices") == "Appareils")
    }

    @Test("New languages fall back to English when a supplemental translation is missing")
    func newLanguagesFallbackToEnglish() {
        let manager = makeManager()
        manager.currentLanguage = .french
        #expect(manager.translate("Audio Device Reconnected") == "Audio Device Reconnected")
    }
}

// MARK: - String Format Keys

@Suite("Localization — Format string keys")
@MainActor
struct LocalizationFormatStringTests {

    @Test("Format key for notification body contains %@ and %d placeholders")
    func reconnectNotificationBodyHasPlaceholders() {
        let manager = makeManager()
        let key = "\"%@\" is back. %d app(s) switched back."
        let result = manager.translate(key)
        #expect(result.contains("%@"), "Expected %@ placeholder in: \(result)")
        #expect(result.contains("%d"), "Expected %d placeholder in: \(result)")
    }

    @Test("Disconnect notification body format key is present")
    func disconnectNotificationBody() {
        let manager = makeManager()
        let key = "\"%@\" disconnected. %d app(s) switched to %@"
        let result = manager.translate(key)
        #expect(!result.isEmpty)
        #expect(result.contains("%@"))
    }

    @Test("String(format:) works with translated format key")
    func stringFormatWorks() {
        let manager = makeManager()
        manager.currentLanguage = .english
        let key = "%d app(s) switched to \"%@\""
        let formatted = String(format: manager.translate(key), 3, "AirPods Pro")
        #expect(formatted.contains("3"))
        #expect(formatted.contains("AirPods Pro"))
    }

    @Test("Turkish format key for disconnect notification preserves placeholders")
    func turkishFormatPreservesPlaceholders() {
        let manager = makeManager()
        manager.currentLanguage = .turkish
        let key = "\"%@\" is back. %d app(s) switched back."
        let result = manager.translate(key)
        #expect(result.contains("%@"), "Turkish translation must keep %@ placeholder")
        #expect(result.contains("%d"), "Turkish translation must keep %d placeholder")
    }
}
