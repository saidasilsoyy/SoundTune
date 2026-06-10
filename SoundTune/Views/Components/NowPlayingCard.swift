// SoundTune/Views/Components/NowPlayingCard.swift
import SwiftUI

/// Compact Now Playing card with artwork, transport controls, and seek progress.
struct NowPlayingCard: View {
    let source: NowPlayingSource
    let appIcon: NSImage
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onSeek: (Double) -> Void

    @State private var scrubPosition: Double? = nil
    @State private var playbackBaselinePosition: Double = 0
    @State private var playbackBaselineDate = Date()
    @State private var pendingSeekPosition: Double?
    @State private var pendingSeekDate: Date?

    var body: some View {
        HStack(spacing: 10) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                metadata
                    .frame(maxWidth: .infinity, alignment: .leading)

                if source.canTransport {
                    transportRow
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 22)
                        .offset(y: -3)
                }

                if source.duration > 0 {
                    progressSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 10)
        .background(DesignTokens.Colors.eqCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .strokeBorder(DesignTokens.Colors.eqCardBorder, lineWidth: 0.5)
        )
        .onAppear { syncPlaybackBaseline() }
        .onChange(of: source.position) { _, _ in reconcileSourcePosition() }
        .onChange(of: source.isPlaying) { _, _ in
            guard pendingSeekPosition == nil else { return }
            syncPlaybackBaseline()
        }
        .onChange(of: source.title) { _, _ in
            clearPendingSeek()
            syncPlaybackBaseline()
        }
    }

    // MARK: - Artwork

    private var artwork: some View {
        Group {
            if let art = source.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    .background(DesignTokens.Colors.recessedBackground)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .help(source.title)
            if !source.subtitle.isEmpty {
                Text(source.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 8) {
            transportButton("backward.fill", size: 11, action: onPrevious, label: t("Previous"))
                .opacity(source.canSkip ? 1 : 0)
                .allowsHitTesting(source.canSkip)
            transportButton(
                source.isPlaying ? "pause.fill" : "play.fill",
                size: 17, action: onPlayPause,
                label: source.isPlaying ? t("Pause") : t("Play")
            )
            transportButton("forward.fill", size: 11, action: onNext, label: t("Next"))
                .opacity(source.canSkip ? 1 : 0)
                .allowsHitTesting(source.canSkip)
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void, label: String) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size + 10, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Progress / Seek

    @ViewBuilder
    private var progressSection: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let position = displayPosition(at: context.date)
            VStack(spacing: 3) {
                if source.canSeek {
                    seekSlider(position: position)
                } else {
                    readOnlyBar(position: position)
                }
                timeRow(position: position)
            }
        }
    }

    private func seekSlider(position: Double) -> some View {
        LiquidGlassSlider(
            value: Binding(
                get: { scrubPosition ?? position },
                set: { scrubPosition = $0 }
            ),
            in: 0...max(1, source.duration),
            trackHeight: 4
        ) { editing in
            if !editing {
                if let pos = scrubPosition {
                    beginPendingSeek(to: pos)
                    onSeek(pos)
                }
                scrubPosition = nil
            }
        }
    }

    private func readOnlyBar(position: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.Colors.textTertiary.opacity(0.3))
                Capsule()
                    .fill(DesignTokens.Colors.accentPrimary)
                    .frame(width: progressFraction(for: position) * geo.size.width)
            }
        }
        .frame(height: 3)
    }

    private func timeRow(position: Double) -> some View {
        HStack {
            Text(Self.formatTime(position))
            Spacer()
            Text("-" + Self.formatTime(max(0, source.duration - position)))
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(DesignTokens.Colors.textTertiary)
    }

    private func progressFraction(for position: Double) -> CGFloat {
        guard source.duration > 0 else { return 0 }
        return max(0, min(1, CGFloat(position / source.duration)))
    }

    private func displayPosition(at date: Date) -> Double {
        if let scrubPosition {
            return scrubPosition
        }
        let elapsed = source.isPlaying ? date.timeIntervalSince(playbackBaselineDate) : 0
        return max(0, min(source.duration, playbackBaselinePosition + elapsed))
    }

    private func syncPlaybackBaseline() {
        playbackBaselinePosition = source.position
        playbackBaselineDate = Date()
    }

    private func beginPendingSeek(to position: Double) {
        let now = Date()
        pendingSeekPosition = position
        pendingSeekDate = now
        playbackBaselinePosition = position
        playbackBaselineDate = now
    }

    private func reconcileSourcePosition() {
        guard let pendingPosition = pendingSeekPosition,
              let pendingDate = pendingSeekDate
        else {
            syncPlaybackBaseline()
            return
        }

        let age = Date().timeIntervalSince(pendingDate)
        let expectedPosition = pendingPosition + (source.isPlaying ? age : 0)
        let sourceConfirmedSeek = abs(source.position - expectedPosition) < 2

        guard sourceConfirmedSeek || age > 2.5 else { return }
        clearPendingSeek()
        syncPlaybackBaseline()
    }

    private func clearPendingSeek() {
        pendingSeekPosition = nil
        pendingSeekDate = nil
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
