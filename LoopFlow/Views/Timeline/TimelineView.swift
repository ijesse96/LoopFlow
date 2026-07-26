import SwiftUI

struct TimelineView: View {
    @ObservedObject var vm: ProjectViewModel

    private var totalBars: Int { max(1, vm.visibleTimelineBars) }
    private var timelineWidth: CGFloat { CGFloat(totalBars) * vm.pixelsPerBar }
    private var rulerHeight: CGFloat {
        ArrangeMetrics.rulerHeight(loopEnabled: vm.project.loopEnabled)
    }

    private var arrangeHeight: CGFloat {
        rulerHeight + ArrangeMetrics.laneHeight * CGFloat(vm.project.tracks.count)
    }

    @State private var trimBaseline: AudioClip?
    @State private var moveUndoPushed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            gridLayer
            selectionOverlay
            clipLayer
            playheadLayer
            snapIndicator
            emptyHint
            BarRulerView(vm: vm)
                .allowsHitTesting(true)
                .zIndex(5)
        }
        .frame(width: timelineWidth, height: arrangeHeight, alignment: .topLeading)
        .background(AppTheme.background)
    }
    private var gridLayer: some View {
        Canvas { context, size in
            let beatsPerBar = vm.project.timeSignature.beatsPerBar
            let barWidth = vm.pixelsPerBar
            let beatWidth = barWidth / CGFloat(beatsPerBar)
            let rulerHeight = ArrangeMetrics.rulerHeight(loopEnabled: vm.project.loopEnabled)
            let laneHeight = ArrangeMetrics.laneHeight
            let subdiv = vm.gridSubdivision

            for bar in 0..<totalBars {
                let x = CGFloat(bar) * barWidth
                var barPath = Path()
                barPath.move(to: CGPoint(x: x, y: rulerHeight))
                barPath.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(barPath, with: .color(AppTheme.gridLine), lineWidth: 1)

                if subdiv >= 1 {
                    for beat in 1..<beatsPerBar {
                        let bx = x + CGFloat(beat) * beatWidth
                        var beatPath = Path()
                        beatPath.move(to: CGPoint(x: bx, y: rulerHeight))
                        beatPath.addLine(to: CGPoint(x: bx, y: size.height))
                        context.stroke(beatPath, with: .color(AppTheme.beatLine), lineWidth: 1)

                        if subdiv >= 4 {
                            for s in 1..<4 {
                                let sx = bx - beatWidth + CGFloat(s) * (beatWidth / 4)
                                if sx <= x { continue }
                                var sub = Path()
                                sub.move(to: CGPoint(x: sx, y: rulerHeight))
                                sub.addLine(to: CGPoint(x: sx, y: size.height))
                                context.stroke(sub, with: .color(AppTheme.beatLine.opacity(0.5)), lineWidth: 0.5)
                            }
                        }
                    }
                }
            }

            for i in 0..<vm.project.tracks.count {
                let y = rulerHeight + CGFloat(i) * laneHeight
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(AppTheme.border), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if vm.project.loopEnabled {
            let sel = vm.project.currentRegion
            let x = CGFloat(sel.startBar - 1) * vm.pixelsPerBar
            let w = CGFloat(sel.lengthBars) * vm.pixelsPerBar
            Rectangle()
                .fill(AppTheme.regionHighlight.opacity(0.55))
                .frame(width: w, height: arrangeHeight - rulerHeight)
                .offset(x: x, y: rulerHeight)
                .allowsHitTesting(false)
        }
    }

    private var clipLayer: some View {
        // VStack (not .offset) so hit-testing matches the visible lane.
        VStack(spacing: 0) {
            ForEach(Array(vm.project.tracks.enumerated()), id: \.element.id) { _, track in
                let isSelectedLane = vm.project.selectedTrackId == track.id
                let dimRecordingClips: Bool = {
                    guard vm.recording.phase == .loopRecording || vm.recording.phase == .countIn,
                          let idx = vm.project.recordingTrackIndex else { return false }
                    return vm.project.tracks[idx].id == track.id
                }()
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(isSelectedLane ? AppTheme.accent.opacity(0.08) : Color.clear)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.selectTrack(id: track.id)
                            vm.selectClip(nil)
                            vm.snapIndicatorBeats = nil
                            moveUndoPushed = false
                            trimBaseline = nil
                        }
                        .zIndex(0)

                    ForEach(track.clips) { clip in
                        let width = max(
                            24,
                            CGFloat(clip.timelineDurationBeats(bpm: vm.project.bpm)) * vm.pixelsPerBeat()
                        )
                        let x = CGFloat(clip.timelineStartBeats) * vm.pixelsPerBeat()
                        let peaks = vm.downsamplePeaks(
                            track.type == .instrumental && clip.waveformPeaks.isEmpty
                                ? track.waveformPeaks
                                : clip.waveformPeaks,
                            forWidth: width
                        )
                        // Position with leading padding (not .offset) so hit targets match visuals.
                        HStack(spacing: 0) {
                            Color.clear.frame(width: max(0, x), height: 1)
                            AudioClipView(
                                clip: clip,
                                isSelected: vm.timelineInteraction.selectedClipId == clip.id,
                                bpm: vm.project.bpm,
                                beatsPerBar: vm.project.timeSignature.beatsPerBar,
                                pixelsPerBeat: vm.pixelsPerBeat(),
                                laneHeight: ArrangeMetrics.laneHeight,
                                peaks: peaks,
                                onSelect: { presentSheet in
                                    vm.selectTrack(id: track.id)
                                    vm.selectClip(clip.id, presentSheet: presentSheet)
                                },
                                onMove: { beats in
                                    if !moveUndoPushed {
                                        vm.pushUndo()
                                        moveUndoPushed = true
                                    }
                                    relocateLive(clipId: clip.id, toBeats: beats)
                                },
                                onTrimLeading: { beatDelta in
                                    applyTrim(clipId: clip.id, leadingBeatDelta: beatDelta, trailingBeatDelta: 0)
                                },
                                onTrimTrailing: { beatDelta in
                                    applyTrim(clipId: clip.id, leadingBeatDelta: 0, trailingBeatDelta: beatDelta)
                                },
                                onDragEnded: {
                                    finishClipDrag(clipId: clip.id)
                                }
                            )
                            Spacer(minLength: 0)
                        }
                        .frame(width: timelineWidth, height: ArrangeMetrics.laneHeight, alignment: .leading)
                        .opacity(dimRecordingClips ? 0.4 : 1)
                        .zIndex(2)
                    }
                }
                .frame(width: timelineWidth, height: ArrangeMetrics.laneHeight)
                .clipped()
            }
        }
        .padding(.top, rulerHeight)
        .frame(width: timelineWidth, alignment: .topLeading)
        .zIndex(2)
    }

    private func relocateLive(clipId: UUID, toBeats: Double) {
        guard let found = vm.clip(id: clipId) else { return }
        var c = found.clip
        c.timelineStartBeats = vm.snapBeats(max(0, toBeats))
        vm.snapIndicatorBeats = c.timelineStartBeats
        vm.project.tracks[found.trackIndex].clips[found.clipIndex] = c
    }

    private func applyTrim(clipId: UUID, leadingBeatDelta: Double, trailingBeatDelta: Double) {
        guard let found = vm.clip(id: clipId) else { return }
        if trimBaseline?.id != clipId {
            vm.pushUndo()
            trimBaseline = found.clip
        }
        guard let base = trimBaseline else { return }
        var c = base
        let leadSec = vm.project.beatsToSeconds(leadingBeatDelta)
        let trailSec = vm.project.beatsToSeconds(trailingBeatDelta)
        c.sourceStartSeconds = max(0, base.sourceStartSeconds + leadSec)
        c.sourceEndSeconds = max(c.sourceStartSeconds + 0.05, base.sourceEndSeconds + trailSec)
        if leadingBeatDelta != 0 {
            c.timelineStartBeats = base.timelineStartBeats + leadingBeatDelta
            if vm.project.snapEnabled {
                c.timelineStartBeats = vm.snapBeats(c.timelineStartBeats)
            }
        }
        // Refresh waveform slice for instrumental so the visible shape matches the window.
        if vm.project.tracks[found.trackIndex].type == .instrumental {
            let full = vm.project.tracks[found.trackIndex].waveformPeaks
            let duration = max(vm.project.instrumentalDurationSeconds, c.sourceEndSeconds)
            c.waveformPeaks = TimelineManager.slicePeaks(
                full.isEmpty ? base.waveformPeaks : full,
                sourceStart: c.sourceStartSeconds,
                sourceEnd: c.sourceEndSeconds,
                totalDuration: duration
            )
        }
        vm.project.tracks[found.trackIndex].clips[found.clipIndex] = c
    }

    private func finishClipDrag(clipId: UUID) {
        guard let found = vm.clip(id: clipId) else {
            moveUndoPushed = false
            trimBaseline = nil
            vm.snapIndicatorBeats = nil
            return
        }
        if vm.project.tracks[found.trackIndex].type == .instrumental {
            vm.refreshInstrumentalMapping()
        } else {
            vm.refreshClipPlaybackSchedule()
        }
        vm.autosave()
        moveUndoPushed = false
        trimBaseline = nil
        vm.snapIndicatorBeats = nil
    }

    private var playheadLayer: some View {
        let x = vm.xPosition(forBeats: vm.project.secondsToBeats(vm.playheadSeconds))
        return ZStack(alignment: .topLeading) {
            // ScrollViewReader ignores `.offset` — place the anchor in layout space
            // so scrollTo follows the real playhead x (not the leading edge).
            HStack(spacing: 0) {
                Color.clear.frame(width: max(0, x), height: 1)
                Color.clear
                    .frame(width: 1, height: 1)
                    .id(Self.playheadScrollID)
                Spacer(minLength: 0)
            }
            .frame(width: timelineWidth, height: 1, alignment: .leading)
            .allowsHitTesting(false)

            Rectangle()
                .fill(AppTheme.playhead)
                .frame(width: 1.5, height: arrangeHeight)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    static let playheadScrollID = "timelinePlayhead"

    @ViewBuilder
    private var snapIndicator: some View {
        if let beats = vm.snapIndicatorBeats, vm.project.snapEnabled {
            Rectangle()
                .fill(AppTheme.accent.opacity(0.8))
                .frame(width: 1, height: arrangeHeight)
                .offset(x: vm.xPosition(forBeats: beats))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var emptyHint: some View {
        if vm.project.instrumentalTrack?.audioRelativePath == nil {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.title)
                Text("Drop a loop or an audio file.").font(.subheadline)
                Button("Import Instrumental") { vm.showImporter = true }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
            }
            .foregroundStyle(AppTheme.textSecondary)
            .frame(width: 240, height: 110)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                    .foregroundStyle(AppTheme.border)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, rulerHeight + 24)
            .allowsHitTesting(vm.project.instrumentalTrack?.audioRelativePath == nil)
        }
    }
}

struct WaveformLaneView: View {
    let peaks: [Float]
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let mid = size.height / 2
            let step = size.width / CGFloat(peaks.count)
            for (i, peak) in peaks.enumerated() {
                let h = CGFloat(peak) * mid
                let x = CGFloat(i) * step
                var path = Path()
                path.move(to: CGPoint(x: x, y: mid - h))
                path.addLine(to: CGPoint(x: x, y: mid + h))
                context.stroke(path, with: .color(AppTheme.waveform.opacity(0.85)), lineWidth: max(1, step * 0.7))
            }
        }
        .frame(width: width, height: height)
    }
}
