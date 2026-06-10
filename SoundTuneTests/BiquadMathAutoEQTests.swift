// SoundTuneTests/BiquadMathAutoEQTests.swift
import Testing
@testable import SoundTune

// MARK: - High-Pass Filter

@Suite("BiquadMath — High-Pass filter coefficients")
struct BiquadMathHighPassTests {

    @Test("Returns exactly 5 coefficients")
    func coefficientCount() {
        let c = BiquadMath.highPassCoefficients(frequency: 80, q: 0.707, sampleRate: 48000)
        #expect(c.count == 5)
    }

    @Test("All coefficients are finite")
    func allFinite() {
        let c = BiquadMath.highPassCoefficients(frequency: 80, q: 0.707, sampleRate: 48000)
        for (i, v) in c.enumerated() {
            #expect(v.isFinite, "Coefficient[\(i)] is not finite: \(v)")
        }
    }

    @Test("b1 == -2 * b0 (high-pass topology constraint)")
    func topologyConstraint() {
        let c = BiquadMath.highPassCoefficients(frequency: 200, q: 0.707, sampleRate: 48000)
        // From cookbook: b1 = -(1+cosW), b0 = b2 = (1+cosW)/2 → b1 = -2*b0
        #expect(abs(c[1] - (-2.0 * c[0])) < 1e-10, "b1 should equal -2*b0, got b0=\(c[0]) b1=\(c[1])")
    }

    @Test("b0 == b2 (high-pass symmetry)")
    func symmetry() {
        let c = BiquadMath.highPassCoefficients(frequency: 200, q: 0.707, sampleRate: 48000)
        #expect(abs(c[0] - c[2]) < 1e-10, "b0 should equal b2")
    }

    @Test("Higher cutoff produces smaller b0 (less HF content passes at lower freqs)")
    func higherCutoffSmallerB0() {
        let low = BiquadMath.highPassCoefficients(frequency: 50, q: 0.707, sampleRate: 48000)
        let high = BiquadMath.highPassCoefficients(frequency: 5000, q: 0.707, sampleRate: 48000)
        #expect(high[0] < low[0], "Higher cutoff should have smaller b0")
    }

    @Test("Different sample rates produce different coefficients")
    func sampleRateEffect() {
        let c44 = BiquadMath.highPassCoefficients(frequency: 200, q: 0.707, sampleRate: 44100)
        let c48 = BiquadMath.highPassCoefficients(frequency: 200, q: 0.707, sampleRate: 48000)
        #expect(c44[0] != c48[0])
    }
}

// MARK: - AutoEQ Coefficients

@Suite("BiquadMath — AutoEQ filter coefficients")
struct BiquadMathAutoEQCoefficientsTests {

    @Test("Empty filter list returns empty array")
    func emptyFilters() {
        let result = BiquadMath.coefficientsForAutoEQFilters([], sampleRate: 48000)
        #expect(result.isEmpty)
    }

    @Test("Single peaking filter returns 5 coefficients")
    func singlePeakingFilter() {
        let filter = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 3.0, q: 1.4)
        let result = BiquadMath.coefficientsForAutoEQFilters([filter], sampleRate: 48000)
        #expect(result.count == 5)
    }

    @Test("N filters return 5*N coefficients")
    func multipleFilters() {
        let filters = [
            AutoEQFilter(type: .peaking,   frequency: 100,  gainDB:  3.0, q: 1.0),
            AutoEQFilter(type: .lowShelf,  frequency: 200,  gainDB: -2.0, q: 0.7),
            AutoEQFilter(type: .highShelf, frequency: 8000, gainDB:  1.5, q: 0.7),
        ]
        let result = BiquadMath.coefficientsForAutoEQFilters(filters, sampleRate: 48000)
        #expect(result.count == 15)
    }

    @Test("All coefficients are finite for valid filters")
    func allFinite() {
        let filters = [
            AutoEQFilter(type: .peaking,   frequency: 1000, gainDB:  6.0, q: 1.4),
            AutoEQFilter(type: .lowShelf,  frequency: 100,  gainDB: -3.0, q: 0.707),
            AutoEQFilter(type: .highShelf, frequency: 8000, gainDB:  3.0, q: 0.707),
        ]
        let result = BiquadMath.coefficientsForAutoEQFilters(filters, sampleRate: 48000)
        for (i, c) in result.enumerated() {
            #expect(c.isFinite, "Coefficient[\(i)] is not finite: \(c)")
        }
    }

    @Test("Filter above Nyquist is bypassed with unity passthrough")
    func aboveNyquistBypass() {
        // 30kHz filter at 44.1kHz sample rate → above Nyquist (22050 Hz)
        let filter = AutoEQFilter(type: .peaking, frequency: 30000, gainDB: 6.0, q: 1.0)
        let result = BiquadMath.coefficientsForAutoEQFilters([filter], sampleRate: 44100)
        #expect(result.count == 5)
        #expect(result[0] == 1.0, "b0 should be 1.0 (bypass)")
        #expect(result[1] == 0.0, "b1 should be 0.0 (bypass)")
        #expect(result[2] == 0.0, "b2 should be 0.0 (bypass)")
        #expect(result[3] == 0.0, "a1 should be 0.0 (bypass)")
        #expect(result[4] == 0.0, "a2 should be 0.0 (bypass)")
    }

    @Test("Pre-warping is applied when sampleRate differs from profileOptimizedRate")
    func preWarpingApplied() {
        let filter = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 3.0, q: 1.4)
        let sameRate = BiquadMath.coefficientsForAutoEQFilters(
            [filter], sampleRate: 48000, profileOptimizedRate: 48000)
        let diffRate = BiquadMath.coefficientsForAutoEQFilters(
            [filter], sampleRate: 44100, profileOptimizedRate: 48000)
        // Different sample rates should produce different coefficients due to pre-warping
        #expect(sameRate[0] != diffRate[0] || sameRate[1] != diffRate[1],
                "Pre-warping should change coefficients for different sample rates")
    }

    @Test("Pre-warping not applied when rates match (within 1 Hz)")
    func noPreWarpWhenRatesMatch() {
        let filter = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 3.0, q: 1.4)
        let same1 = BiquadMath.coefficientsForAutoEQFilters(
            [filter], sampleRate: 48000, profileOptimizedRate: 48000)
        let same2 = BiquadMath.coefficientsForAutoEQFilters(
            [filter], sampleRate: 48000, profileOptimizedRate: 48000.5) // < 1 Hz diff
        for i in 0..<5 {
            #expect(abs(same1[i] - same2[i]) < 1e-10,
                    "Coefficient[\(i)] should match when rates are within 1 Hz")
        }
    }

    @Test("Mixed filter types all produce valid results")
    func mixedFilterTypes() {
        let filters = [
            AutoEQFilter(type: .lowShelf,  frequency: 60,   gainDB:  4.0, q: 0.7),
            AutoEQFilter(type: .peaking,   frequency: 250,  gainDB: -2.0, q: 2.0),
            AutoEQFilter(type: .peaking,   frequency: 1000, gainDB:  1.5, q: 1.4),
            AutoEQFilter(type: .peaking,   frequency: 3000, gainDB: -1.0, q: 1.0),
            AutoEQFilter(type: .highShelf, frequency: 8000, gainDB:  2.0, q: 0.7),
        ]
        let result = BiquadMath.coefficientsForAutoEQFilters(filters, sampleRate: 48000)
        #expect(result.count == 25)
        for (i, c) in result.enumerated() {
            #expect(c.isFinite, "Coefficient[\(i)] not finite")
        }
    }

    @Test("Zero gain peaking filter returns near-unity b0")
    func zeroGainPeakingNearUnity() {
        let filter = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 0, q: 1.4)
        let result = BiquadMath.coefficientsForAutoEQFilters([filter], sampleRate: 48000)
        #expect(abs(result[0] - 1.0) < 1e-10, "Zero-gain filter b0 should be ~1.0, got \(result[0])")
    }
}

// MARK: - Extreme Gain Edge Cases

@Suite("BiquadMath — Extreme gain values")
struct BiquadMathExtremeGainTests {

    @Test("±20dB peaking filter produces finite coefficients")
    func extremePeakingGain() {
        for gainDB: Float in [-20.0, 20.0] {
            let c = BiquadMath.peakingEQCoefficients(
                frequency: 1000, gainDB: gainDB, q: 1.4, sampleRate: 48000)
            for (i, v) in c.enumerated() {
                #expect(v.isFinite, "Coefficient[\(i)] not finite at \(gainDB)dB: \(v)")
            }
        }
    }

    @Test("±20dB shelf filters produce finite coefficients")
    func extremeShelfGain() {
        for gainDB: Float in [-20.0, 20.0] {
            let low = BiquadMath.lowShelfCoefficients(
                frequency: 100, gainDB: gainDB, q: 0.707, sampleRate: 48000)
            let high = BiquadMath.highShelfCoefficients(
                frequency: 8000, gainDB: gainDB, q: 0.707, sampleRate: 48000)
            for (i, v) in (low + high).enumerated() {
                #expect(v.isFinite, "Shelf coefficient[\(i)] not finite at \(gainDB)dB: \(v)")
            }
        }
    }

    @Test("Very high Q value produces finite coefficients")
    func veryHighQ() {
        let c = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 6, q: 100.0, sampleRate: 48000)
        for (i, v) in c.enumerated() {
            #expect(v.isFinite, "High-Q coefficient[\(i)] not finite: \(v)")
        }
    }

    @Test("Very low Q value (0.1) produces finite coefficients")
    func veryLowQ() {
        let c = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 6, q: 0.1, sampleRate: 48000)
        for (i, v) in c.enumerated() {
            #expect(v.isFinite, "Low-Q coefficient[\(i)] not finite: \(v)")
        }
    }

    @Test("Very low frequency (20 Hz) produces finite coefficients")
    func veryLowFrequency() {
        let c = BiquadMath.peakingEQCoefficients(
            frequency: 20, gainDB: 6, q: 1.4, sampleRate: 48000)
        for (i, v) in c.enumerated() {
            #expect(v.isFinite, "Low-freq coefficient[\(i)] not finite: \(v)")
        }
    }

    @Test("coefficientsForAllBands with extreme gains all finite")
    func allBandsExtremeGains() {
        let gains: [Float] = [-12, -12, -12, -12, -12, 12, 12, 12, 12, 12]
        let c = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 48000)
        for (i, v) in c.enumerated() {
            #expect(v.isFinite, "All-bands coefficient[\(i)] not finite: \(v)")
        }
    }
}
