// SoundTune/Views/Components/MiniEQCurveView.swift
import SwiftUI

/// Draws an approximate frequency-response curve for a set of parametric EQ filters.
/// Uses a Gaussian/sigmoidal approximation — visually faithful without full biquad math.
struct MiniEQCurveView: View {
    let filters: [AutoEQFilter]

    /// Number of frequency samples to draw (higher = smoother curve)
    var sampleCount: Int = 60
    /// Peak gain range for y-axis scaling (±dB). Values outside are clamped.
    var peakGainDB: Double = 12.0
    var lineColor: Color = .accentColor
    var lineWidth: CGFloat = 1.2
    var fillOpacity: Double = 0.12

    var body: some View {
        Canvas { ctx, size in
            guard !filters.isEmpty else {
                drawFlatLine(ctx: ctx, size: size)
                return
            }

            let samples = frequencyResponseSamples(count: sampleCount)
            let maxGain = peakGainDB

            var path = Path()
            var fillPath = Path()
            let midY = size.height / 2

            for (i, sample) in samples.enumerated() {
                let x = CGFloat(i) / CGFloat(sampleCount - 1) * size.width
                // Map gain [-maxGain, +maxGain] → y [size.height, 0]
                let normalized = (sample / maxGain).clamped(to: -1...1)
                let y = midY - CGFloat(normalized) * midY

                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                    fillPath.move(to: CGPoint(x: x, y: midY))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // Close fill path
            fillPath.addLine(to: CGPoint(x: size.width, y: midY))
            fillPath.closeSubpath()

            // Draw zero line
            var zeroPath = Path()
            zeroPath.move(to: CGPoint(x: 0, y: midY))
            zeroPath.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(zeroPath, with: .color(lineColor.opacity(0.2)), lineWidth: 0.5)

            // Fill under/over curve
            ctx.fill(fillPath, with: .color(lineColor.opacity(fillOpacity)))

            // Stroke the curve
            ctx.stroke(path, with: .color(lineColor.opacity(0.8)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Frequency Response

    /// Samples the combined gain of all filters at `count` logarithmically-spaced frequencies.
    private func frequencyResponseSamples(count: Int) -> [Double] {
        let minFreq = log10(20.0)
        let maxFreq = log10(20_000.0)

        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let freq = pow(10.0, minFreq + t * (maxFreq - minFreq))
            return filters.reduce(0.0) { $0 + approximateGain(at: freq, for: $1) }
        }
    }

    /// Approximate gain (dB) of a single filter at a given frequency.
    private func approximateGain(at freq: Double, for filter: AutoEQFilter) -> Double {
        let fc = max(1.0, filter.frequency)
        let gain = Double(filter.gainDB)
        let q = max(0.1, filter.q)

        switch filter.type {
        case .peaking:
            // Gaussian approximation: FWHM ≈ fc / Q octaves
            let bwOctaves = max(0.01, 1.0 / (q * 1.44269))
            let octavesFromCenter = log2(freq / fc)
            return gain * exp(-0.5 * pow(octavesFromCenter / bwOctaves, 2.0))

        case .lowShelf:
            // Sigmoidal: transitions from 0 at high freq to gain at low freq
            let octavesFromCenter = log2(freq / fc)
            return gain * (0.5 - 0.5 * tanh(octavesFromCenter * 1.5 * sqrt(q)))

        case .highShelf:
            // Sigmoidal: transitions from 0 at low freq to gain at high freq
            let octavesFromCenter = log2(freq / fc)
            return gain * (0.5 + 0.5 * tanh(octavesFromCenter * 1.5 * sqrt(q)))
        }
    }

    private func drawFlatLine(ctx: GraphicsContext, size: CGSize) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: size.height / 2))
        line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        ctx.stroke(line, with: .color(lineColor.opacity(0.2)), lineWidth: 0.5)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
