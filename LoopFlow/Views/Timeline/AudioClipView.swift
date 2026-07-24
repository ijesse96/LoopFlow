import SwiftUI

struct AudioClipView: View {
    let clip: AudioClip
    let isSelected: Bool
    let bpm: Double
    let beatsPerBar: Int
    let pixelsPerBeat: CGFloat
    let laneHeight: CGFloat
    let peaks: [Float]
    /// `true` = long-press (open edit sheet); `false` = tap (select only).
    let onSelect: (Bool) -> Void
    let onMove: (Double) -> Void
    let onTrimLeading: (Double) -> Void
    let onTrimTrailing: (Double) -> Void
    let onDragEnded: () -> Void

    @State private var dragStartBeats: Double?
    @State private var didMove = false

    private var width: CGFloat {
        let beats = clip.timelineDurationBeats(bpm: bpm)
        return max(24, CGFloat(beats) * pixelsPerBeat)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Button {
                onSelect(true)
            } label: {
                clipChrome
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in onSelect(true) }
            )

            if isSelected {
                trimHandle(leading: true)
                trimHandle(leading: false)
            }
        }
        .frame(width: width, height: laneHeight - 10)
        .opacity(clip.isMuted ? 0.55 : 1)
        .contentShape(Rectangle())
        .modifier(
            ClipMoveWhenSelected(
                isSelected: isSelected,
                onChanged: handleMoveChanged,
                onEnded: handleMoveEnded
            )
        )
    }

    private var clipChrome: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(clip.isMuted ? Color.gray.opacity(0.35) : AppTheme.waveform.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? AppTheme.accent : AppTheme.border, lineWidth: isSelected ? 2 : 1)
                )

            WaveformLaneView(peaks: peaks, width: width - 8, height: laneHeight - 20)
                .padding(.horizontal, 4)
                .allowsHitTesting(false)

            HStack(spacing: 4) {
                if clip.isMuted {
                    Image(systemName: "speaker.slash.fill").font(.caption2)
                }
                if clip.isLooping {
                    Image(systemName: "repeat").font(.caption2)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .foregroundStyle(AppTheme.textPrimary)
            .allowsHitTesting(false)
        }
        .frame(width: width, height: laneHeight - 10)
        .contentShape(Rectangle())
    }

    private func trimHandle(leading: Bool) -> some View {
        let handleW: CGFloat = 22
        return RoundedRectangle(cornerRadius: 3)
            .fill(AppTheme.accent)
            .frame(width: 10, height: laneHeight - 18)
            .overlay(
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8))
                    .foregroundStyle(.white)
            )
            .frame(width: handleW, height: laneHeight - 10)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let beatDelta = Double(value.translation.width / max(pixelsPerBeat, 1))
                        if leading {
                            onTrimLeading(beatDelta)
                        } else {
                            onTrimTrailing(beatDelta)
                        }
                    }
                    .onEnded { _ in
                        onDragEnded()
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leading ? .leading : .trailing)
            .zIndex(30)
    }

    private func handleMoveChanged(_ value: DragGesture.Value) {
        if dragStartBeats == nil {
            dragStartBeats = clip.timelineStartBeats
            didMove = false
        }
        if abs(value.translation.width) > 4 {
            didMove = true
            let delta = Double(value.translation.width / max(pixelsPerBeat, 1))
            onMove((dragStartBeats ?? clip.timelineStartBeats) + delta)
        }
    }

    private func handleMoveEnded() {
        if didMove {
            onDragEnded()
        }
        dragStartBeats = nil
        didMove = false
    }
}

private struct ClipMoveWhenSelected: ViewModifier {
    let isSelected: Bool
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: () -> Void

    func body(content: Content) -> some View {
        if isSelected {
            content.highPriorityGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged(onChanged)
                    .onEnded { _ in onEnded() }
            )
        } else {
            content
        }
    }
}
