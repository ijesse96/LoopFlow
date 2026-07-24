import Foundation
import AVFoundation

enum RecordingPhase: Equatable {
    case idle
    case countIn
    case loopRecording
}

@MainActor
final class RecordingManager: ObservableObject {
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var currentTakeNumber: Int = 0
    @Published var statusMessage: String = ""

    private let audio: AudioEngineManager
    private let storage: ProjectStorageManager

    var onTakeCompleted: ((Take) -> Void)?
    var onAdvanceRegion: (() -> Void)?
    /// Fired when record/count-in arms so the host can drop record-track clips from playback.
    var onClipScheduleRefresh: (() -> Void)?
    /// Fired when async waveform peaks are ready for a kept clip.
    var onClipPeaksReady: ((UUID, [Float]) -> Void)?

    private var projectID: UUID = UUID()
    /// Stable key for takes under the current selection (start bar).
    private var regionIndex: Int = 1
    private var activeTake: Take?

    init(audio: AudioEngineManager, storage: ProjectStorageManager? = nil) {
        self.audio = audio
        self.storage = storage ?? ProjectStorageManager.shared
    }

    func configure(projectID: UUID) {
        self.projectID = projectID
    }

    func syncSelection(from project: LoopFlowProject) {
        regionIndex = project.selectionStartBar
    }

    // MARK: - Transport

    func startRecording(project: LoopFlowProject) {
        guard phase == .idle else { return }
        guard let trackIdx = project.recordingTrackIndex else {
            statusMessage = "Select a vocal/audio track to record"
            return
        }
        let region = project.currentRegion
        regionIndex = region.startBar

        let startBeats = project.barToBeats(project.selectionStartBar)
        let endBeats = project.barToBeats(project.selectionEndBar)
        let hasKeptClip = project.tracks[trackIdx].clips.contains {
            $0.timelineStartBeats >= startBeats - 0.001 && $0.timelineStartBeats < endBeats - 0.001
        }

        audio.updateTransportContext(
            bpm: project.bpm,
            timeSignature: project.timeSignature,
            loopEnabled: project.loopEnabled,
            metronomeEnabled: project.metronomeEnabled
        )
        audio.setActiveRegion(region)
        audio.setMasterVolume(project.masterVolume)
        if let inst = project.instrumentalTrack {
            audio.setInstrumentalVolume(inst.isMuted ? 0 : inst.volume)
        }

        audio.setLoopBoundaryHandler { [weak self] in
            self?.handleLoopBoundary()
        }

        // Count-in only when starting from stop; mid-playback takeovers jump straight to region start.
        let beats = (project.countInEnabled && !audio.isPlaying)
            ? project.timeSignature.beatsPerBar
            : 0
        if beats > 0 {
            phase = .countIn
            onClipScheduleRefresh?()
            statusMessage = hasKeptClip
                ? "Count-in… — Keep will replace existing clip (Undo restores)"
                : "Count-in…"
            try? audio.startCountIn(beats: beats) { [weak self] in
                self?.beginLoopRecording(project: project, replacingKept: hasKeptClip)
            }
        } else {
            beginLoopRecording(project: project, replacingKept: hasKeptClip)
        }
    }

    private func beginLoopRecording(project: LoopFlowProject, replacingKept: Bool = false) {
        phase = .loopRecording
        // Exclude the record-track take before play() schedules clip players.
        onClipScheduleRefresh?()
        currentTakeNumber = nextTakeNumber(in: project)
        guard openNewTakeFile(), audio.isRecording else {
            phase = .idle
            if statusMessage.isEmpty || statusMessage.hasPrefix("Recording") {
                statusMessage = "Could not start recording"
            }
            return
        }
        do {
            try audio.play(fromRegionStart: true)
            statusMessage = replacingKept
                ? "Recording take \(currentTakeNumber) — Keep replaces kept clip (Undo restores)"
                : "Recording take \(currentTakeNumber)"
        } catch {
            statusMessage = error.localizedDescription
            audio.stopRecordingTap()
            phase = .idle
        }
    }

    func stop() {
        let pendingTakeNumber = activeTake?.takeNumber
        if let take = finalizeActiveTake() {
            onTakeCompleted?(take)
            audio.stop()
            audio.setLoopBoundaryHandler(nil)
            phase = .idle
            statusMessage = "Stopped — Keep (A) to place take \(take.takeNumber)"
            return
        }
        audio.stop()
        audio.setLoopBoundaryHandler(nil)
        phase = .idle
        if let n = pendingTakeNumber {
            statusMessage = "Stopped — Keep (A) to place take \(n)"
        } else {
            statusMessage = "Stopped"
        }
    }

    func playOnly(project: LoopFlowProject) {
        guard phase == .idle else { return }
        let region = project.currentRegion
        audio.updateTransportContext(
            bpm: project.bpm,
            timeSignature: project.timeSignature,
            loopEnabled: project.loopEnabled,
            metronomeEnabled: project.metronomeEnabled
        )
        // Keep scrubbed playhead; only refresh region bounds.
        audio.setActiveRegion(region, resetPlayhead: false)
        audio.setArrangementEndSeconds(Self.arrangementEndSeconds(for: project))
        audio.setMasterVolume(project.masterVolume)
        if let inst = project.instrumentalTrack {
            audio.setInstrumentalVolume(inst.isMuted ? 0 : inst.volume)
        }
        audio.setLoopBoundaryHandler(nil)
        try? audio.play(fromRegionStart: false)
    }

    static func arrangementEndSeconds(for project: LoopFlowProject) -> Double {
        var end = max(0, project.instrumentalDurationSeconds)
        if let inst = project.instrumentalTrack, let clip = inst.clips.first {
            let clipEnd = project.beatsToSeconds(clip.timelineStartBeats)
                + max(0, clip.sourceEndSeconds - clip.sourceStartSeconds)
            end = max(end, clipEnd)
        }
        for track in project.tracks where track.type != .instrumental {
            for clip in track.clips {
                let clipEnd = project.beatsToSeconds(clip.timelineStartBeats)
                    + max(0, clip.sourceEndSeconds - clip.sourceStartSeconds)
                end = max(end, clipEnd)
            }
        }
        let contentEnd = project.beatsToSeconds(project.barToBeats(project.contentEndBar + 1))
        return max(end, contentEnd)
    }

    func togglePlay(project: LoopFlowProject) {
        if audio.isPlaying && phase == .idle {
            audio.stop()
        } else if phase == .idle {
            playOnly(project: project)
        }
    }

    // MARK: - Takes

    private func nextTakeNumber(in project: LoopFlowProject) -> Int {
        guard let trackIdx = project.recordingTrackIndex else { return 1 }
        let existing = project.tracks[trackIdx].takes.filter { $0.regionIndex == regionIndex }
        return (existing.map(\.takeNumber).max() ?? 0) + 1
    }

    @discardableResult
    private func openNewTakeFile() -> Bool {
        let relative = storage.makeTakeRelativePath(regionIndex: regionIndex, takeNumber: currentTakeNumber)
        guard let url = try? storage.takeFileURL(projectID: projectID, relativePath: relative) else {
            statusMessage = "Could not create take file"
            return false
        }
        do {
            if audio.isRecording {
                try audio.rotateRecordingFile(to: url)
            } else {
                try audio.beginRecording(to: url)
            }
            activeTake = Take(
                regionIndex: regionIndex,
                takeNumber: currentTakeNumber,
                relativePath: relative
            )
            return true
        } catch {
            statusMessage = error.localizedDescription
            activeTake = nil
            return false
        }
    }

    private func handleLoopBoundary() {
        guard phase == .loopRecording else { return }
        let completed = activeTake
        activeTake = nil
        currentTakeNumber += 1
        openNewTakeFile()
        if var take = completed {
            take.recordedLatencySeconds = audio.activeRecordingLatencySeconds
            if let url = try? storage.takeFileURL(projectID: projectID, relativePath: take.relativePath) {
                take.durationSeconds = audio.measureTakeDuration(url: url)
            }
            onTakeCompleted?(take)
        }
        statusMessage = "Recording take \(currentTakeNumber)"
    }

    @discardableResult
    private func finalizeActiveTake() -> Take? {
        guard var take = activeTake else { return nil }
        activeTake = nil
        audio.closeCurrentRecordingFile()
        take.recordedLatencySeconds = audio.activeRecordingLatencySeconds
        if let url = try? storage.takeFileURL(projectID: projectID, relativePath: take.relativePath) {
            take.durationSeconds = audio.measureTakeDuration(url: url)
        }
        return take
    }

    // MARK: - Accept / redo / navigate

    /// Places the last usable take as a clip. Returns `true` when a clip was written or advance-only succeeded.
    @discardableResult
    func keepTake(advance: Bool, project: inout LoopFlowProject) -> Bool {
        guard let trackIdx = project.recordingTrackIndex else {
            statusMessage = "Select a vocal/audio track to record"
            return false
        }

        let startBeats = project.barToBeats(project.selectionStartBar)
        let endBeats = project.barToBeats(project.selectionEndBar)
        let selectionHasClip = project.tracks[trackIdx].clips.contains {
            $0.timelineStartBeats >= startBeats - 0.001 && $0.timelineStartBeats < endBeats - 0.001
        }

        // Keep+Next after Keep: don't re-keep / replace — just advance.
        if advance, selectionHasClip {
            if let take = finalizeActiveTake() {
                // Drop empty aborted take; keep longer alternates as non-accepted.
                if take.durationSeconds > 0.05 {
                    var stored = take
                    stored.isAccepted = false
                    if !project.tracks[trackIdx].takes.contains(where: { $0.id == stored.id }) {
                        project.tracks[trackIdx].takes.append(stored)
                    }
                }
            }
            advanceRegion(project: &project, continueRecording: phase == .loopRecording)
            return true
        }

        let finalized = finalizeActiveTake()
        var finalizedHasDuration = false
        if var take = finalized {
            if let url = try? storage.takeFileURL(projectID: projectID, relativePath: take.relativePath) {
                take.durationSeconds = audio.measureTakeDuration(url: url)
            }
            if let existing = project.tracks[trackIdx].takes.firstIndex(where: { $0.id == take.id }) {
                project.tracks[trackIdx].takes[existing] = take
            } else {
                project.tracks[trackIdx].takes.append(take)
            }
            // Drop empty in-progress files so they are never chosen as "latest".
            if take.durationSeconds <= 0.05 {
                project.tracks[trackIdx].takes.removeAll { $0.id == take.id }
            } else {
                finalizedHasDuration = true
            }
        }

        // Prefer the last take with real audio (completed loop), not an empty post-boundary file.
        // While recording with a good finalized take, skip remeasuring older WAVs (monitor underruns).
        let skipRemeasure = phase == .loopRecording && finalizedHasDuration
        var usable: [Take] = []
        for var take in project.tracks[trackIdx].takes where take.regionIndex == regionIndex {
            if !skipRemeasure,
               take.durationSeconds <= 0.05,
               let url = try? storage.takeFileURL(projectID: projectID, relativePath: take.relativePath) {
                take.durationSeconds = audio.measureTakeDuration(url: url)
                if let idx = project.tracks[trackIdx].takes.firstIndex(where: { $0.id == take.id }) {
                    project.tracks[trackIdx].takes[idx] = take
                }
            }
            if take.durationSeconds > 0.05 {
                usable.append(take)
            }
        }
        guard var chosen = usable.max(by: { $0.takeNumber < $1.takeNumber }) else {
            statusMessage = "Empty recording — check mic"
            if phase == .loopRecording, activeTake == nil {
                currentTakeNumber = nextTakeNumber(in: project)
                openNewTakeFile()
            }
            return false
        }
        // Prefer an already-accepted take only when the newer file is aborted vs current region length
        // (Keep → Keep+Next race), not when the user deliberately recorded a shorter region.
        let expectedSeconds = project.currentRegion.durationSeconds(
            bpm: project.bpm,
            timeSignature: project.timeSignature
        )
        if let accepted = usable.filter(\.isAccepted).max(by: { $0.takeNumber < $1.takeNumber }),
           accepted.id != chosen.id,
           chosen.durationSeconds < max(0.25, expectedSeconds * 0.25) {
            chosen = accepted
        }

        for i in project.tracks[trackIdx].takes.indices {
            if project.tracks[trackIdx].takes[i].regionIndex == regionIndex {
                project.tracks[trackIdx].takes[i].isAccepted =
                    project.tracks[trackIdx].takes[i].id == chosen.id
            }
        }

        let takeURL = try? storage.takeFileURL(projectID: projectID, relativePath: chosen.relativePath)
        var duration = chosen.durationSeconds
        if let takeURL, !skipRemeasure || duration <= 0.05 {
            let measured = audio.measureTakeDuration(url: takeURL)
            if measured > 0.05 {
                duration = measured
            }
        }
        if duration <= 0.05 {
            statusMessage = "Empty recording — check mic"
            if phase == .loopRecording, activeTake == nil {
                currentTakeNumber = nextTakeNumber(in: project)
                openNewTakeFile()
            }
            return false
        }

        // Align to what was heard: instrumental arrives late (output) and mic late (input).
        let baseLatency = chosen.recordedLatencySeconds > 0
            ? chosen.recordedLatencySeconds
            : audio.roundTripLatencySeconds
        let latency = max(0, baseLatency + audio.recordingLatencyOffsetSeconds)
        var sourceStart = min(latency, max(0, duration - 0.05))

        // If the take has a clear onset in the lead-in window, never under-trim past it.
        // Catches under-reported I/O latency when the performer hits near the 1.
        if let takeURL,
           let onset = TimelineManager.findFirstSoundTime(
            url: takeURL,
            maxScanSeconds: min(0.35, max(0.05, duration))
           ),
           onset > 0.005,
           onset < 0.25 {
            sourceStart = min(max(latency, onset), max(0, duration - 0.05))
        }

        let hadExistingClip = selectionHasClip
        // Replace any clip that starts inside the current selection.
        project.tracks[trackIdx].clips.removeAll {
            $0.timelineStartBeats >= startBeats - 0.001 && $0.timelineStartBeats < endBeats - 0.001
        }
        var newClip = AudioClip(
            trackId: project.tracks[trackIdx].id,
            sourceRelativePath: chosen.relativePath,
            sourceStartSeconds: sourceStart,
            sourceEndSeconds: duration,
            timelineStartBeats: startBeats,
            waveformPeaks: []
        )
        project.tracks[trackIdx].clips.append(newClip)

        statusMessage = hadExistingClip
            ? "Kept take \(chosen.takeNumber) — replaced previous (Undo to restore)"
            : "Kept take \(chosen.takeNumber)"

        // Re-arm recording before peak generation so monitor stays live.
        if advance {
            advanceRegion(project: &project, continueRecording: phase == .loopRecording)
        } else if phase == .loopRecording {
            currentTakeNumber = nextTakeNumber(in: project)
            openNewTakeFile()
            // Same-region Keep: clock never stopped — re-arm writes immediately.
            audio.armRecordingWritesAlignedToClock()
        }

        if let takeURL {
            let clipId = newClip.id
            let peaksStart = sourceStart
            let peaksEnd = duration
            let stillRecording = phase == .loopRecording
            if stillRecording {
                // Defer heavy file read so Keep+Next does not stall the mic monitor.
                Task.detached(priority: .utility) { [weak self] in
                    let peaks = TimelineManager.generateWaveformPeaks(
                        url: takeURL,
                        targetCount: 800,
                        sourceStartSeconds: peaksStart,
                        sourceEndSeconds: peaksEnd
                    )
                    await MainActor.run {
                        self?.onClipPeaksReady?(clipId, peaks)
                    }
                }
            } else {
                let peaks = TimelineManager.generateWaveformPeaks(
                    url: takeURL,
                    targetCount: 800,
                    sourceStartSeconds: sourceStart,
                    sourceEndSeconds: duration
                )
                if let clipIdx = project.tracks[trackIdx].clips.firstIndex(where: { $0.id == newClip.id }) {
                    project.tracks[trackIdx].clips[clipIdx].waveformPeaks = peaks
                }
            }
        }
        return true
    }

    func redoRegion(project: inout LoopFlowProject) {
        guard let trackIdx = project.recordingTrackIndex else { return }
        for i in project.tracks[trackIdx].takes.indices where project.tracks[trackIdx].takes[i].regionIndex == regionIndex {
            project.tracks[trackIdx].takes[i].isAccepted = false
        }
        let startBeats = project.barToBeats(project.selectionStartBar)
        let endBeats = project.barToBeats(project.selectionEndBar)
        project.tracks[trackIdx].clips.removeAll {
            $0.timelineStartBeats >= startBeats - 0.001 && $0.timelineStartBeats < endBeats - 0.001
        }
        statusMessage = "Redo selection"
    }

    func advanceRegion(project: inout LoopFlowProject, continueRecording: Bool) {
        let before = project.selectionStartBar
        project.advanceSelection()
        if project.selectionStartBar == before {
            statusMessage = "Last region reached"
            if continueRecording { stop() }
            return
        }
        regionIndex = project.selectionStartBar
        audio.setActiveRegion(project.currentRegion)
        statusMessage = "Bars \(project.selectionStartBar)–\(project.selectionEndBar - 1)"
        onAdvanceRegion?()

        if continueRecording, phase == .loopRecording {
            currentTakeNumber = nextTakeNumber(in: project)
            openNewTakeFile()
            audio.restartPlaybackFromPlayhead()
        }
    }

    func previousRegion(project: inout LoopFlowProject) {
        project.retreatSelection()
        regionIndex = project.selectionStartBar
        audio.setActiveRegion(project.currentRegion)
        if phase == .loopRecording {
            currentTakeNumber = nextTakeNumber(in: project)
            openNewTakeFile()
            audio.restartPlaybackFromPlayhead()
        }
        statusMessage = "Bars \(project.selectionStartBar)–\(project.selectionEndBar - 1)"
    }

    func nextRegion(project: inout LoopFlowProject) {
        advanceRegion(project: &project, continueRecording: phase == .loopRecording)
    }
}
