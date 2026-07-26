import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Combine

@MainActor
final class ProjectViewModel: ObservableObject {
    @Published var project: LoopFlowProject
    @Published var isInStudio = false
    @Published var sessionSummaries: [ProjectSummary] = []
    @Published var showImporter = false
    @Published var showSettings = false
    @Published var showExport = false
    @Published var showSetupSheet = false
    @Published var pixelsPerBar: CGFloat = 64
    @Published var exportMessage: String?
    @Published var isBusy = false
    @Published var clipboard: ClipClipboard?
    @Published var snapIndicatorBeats: Double?
    /// Fine-tune Keep latency trim (ms). Positive trims more leading audio (fixes late takes).
    @Published var recordingLatencyOffsetMs: Int = UserDefaults.standard.integer(
        forKey: AudioEngineManager.recordingLatencyOffsetKey
    ) {
        didSet {
            UserDefaults.standard.set(recordingLatencyOffsetMs, forKey: AudioEngineManager.recordingLatencyOffsetKey)
        }
    }

    let audio = AudioEngineManager()
    lazy var recording: RecordingManager = RecordingManager(audio: audio)
    let controller = ControllerInputManager()
    let storage = ProjectStorageManager.shared
    let exporter = ExportManager()
    let timelineInteraction = TimelineInteractionState()
    let editHistory = EditCommandHistory()

    private var cancellables = Set<AnyCancellable>()

    init() {
        do {
            project = try ProjectStorageManager.shared.loadLastOpenedOrCreate()
        } catch {
            project = LoopFlowProject()
        }
        project.ensureClipsMigrated()
        project.ensureSelectedTrack()
        recording.configure(projectID: project.id)
        recording.syncSelection(from: project)
        bindRecording()
        bindController()
        forwardChildChanges()
        applyAudioFromProject()
        audio.onRouteChange = { [weak self] in
            guard let self else { return }
            self.applyInputMonitor()
            if let track = self.project.tracks.first(where: \.inputMonitorEnabled),
               !self.audio.isHeadphoneOrBluetoothOutput {
                self.recording.statusMessage = "Monitoring needs headphones"
            }
        }
        applyInputMonitor()
        isInStudio = false
        refreshSessionSummaries()
    }

    private func forwardChildChanges() {
        audio.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        recording.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        timelineInteraction.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func bindRecording() {
        recording.onTakeCompleted = { [weak self] take in
            guard let self else { return }
            guard let trackIdx = self.project.recordingTrackIndex else { return }
            if let existing = self.project.tracks[trackIdx].takes.firstIndex(where: { $0.id == take.id }) {
                self.project.tracks[trackIdx].takes[existing] = take
            } else {
                self.project.tracks[trackIdx].takes.append(take)
            }
            self.autosave()
        }
        recording.onClipScheduleRefresh = { [weak self] in
            self?.refreshClipPlaybackSchedule()
        }
        recording.onClipPeaksReady = { [weak self] clipId, peaks in
            guard let self else { return }
            for trackIdx in self.project.tracks.indices {
                if let clipIdx = self.project.tracks[trackIdx].clips.firstIndex(where: { $0.id == clipId }) {
                    self.project.tracks[trackIdx].clips[clipIdx].waveformPeaks = peaks
                    self.autosave()
                    return
                }
            }
        }
    }

    private func bindController() {
        controller.updateMappings(project.keyMappings)
        controller.onAction = { [weak self] action in
            self?.handleControllerAction(action)
        }
    }

    func handleControllerAction(_ action: ControllerAction) {
        switch action {
        case .keepTake:
            let before = project
            let ok = recording.keepTake(advance: false, project: &project)
            if ok {
                editHistory.push(before)
                // While armed the record track is already excluded — rebuilding the
                // schedule under a live mic causes monitor static.
                if recording.phase != .loopRecording {
                    refreshClipPlaybackSchedule()
                }
                autosave()
            }
        case .keepTakeAndNext:
            let wasRecording = recording.phase == .loopRecording
            let before = project
            let ok = recording.keepTake(advance: true, project: &project)
            if ok {
                editHistory.push(before)
                recording.syncSelection(from: project)
                if recording.phase == .loopRecording {
                    // Still armed — region/file already rotated in RecordingManager.
                    // Do not rebuild clip graph or reload audio (monitor static).
                    audio.setArrangementEndSeconds(RecordingManager.arrangementEndSeconds(for: project))
                } else if wasRecording {
                    // Hit last region / stopped during keep — settle idle monitor.
                    applyAudioFromProject()
                    applyInputMonitor()
                } else {
                    // Idle Keep+Next: advance then auto-arm record on the new region.
                    applyAudioFromProject()
                    requestMicAndRecord(leadIn: false)
                }
                autosave()
            }
        case .previousRegion:
            recording.previousRegion(project: &project)
            recording.syncSelection(from: project)
            if recording.phase == .loopRecording {
                audio.setActiveRegion(project.currentRegion, resetPlayhead: false)
                audio.setArrangementEndSeconds(RecordingManager.arrangementEndSeconds(for: project))
            } else {
                applyAudioFromProject()
            }
            autosave()
        case .nextRegion:
            recording.nextRegion(project: &project)
            recording.syncSelection(from: project)
            if recording.phase == .loopRecording {
                audio.setActiveRegion(project.currentRegion, resetPlayhead: false)
                audio.setArrangementEndSeconds(RecordingManager.arrangementEndSeconds(for: project))
            } else {
                applyAudioFromProject()
            }
            autosave()
        case .redoRegion:
            pushUndo()
            recording.redoRegion(project: &project)
            autosave()
        case .undo:
            performUndo()
        case .record:
            toggleRecord()
        case .leadIn:
            startLeadInRecord()
        case .stop:
            recording.stop()
            applyInputMonitor()
            refreshClipPlaybackSchedule()
        }
    }

    // MARK: - Transport

    func toggleRecord() {
        if recording.phase == .idle {
            if let track = project.selectedTrack, track.type == .instrumental {
                recording.statusMessage = "Select a vocal/audio track to record"
                return
            }
            if project.recordingTrackIndex == nil {
                recording.statusMessage = "Select a vocal/audio track to record"
                return
            }
            requestMicAndRecord(leadIn: false)
        } else {
            recording.stop()
            applyInputMonitor()
            refreshClipPlaybackSchedule()
        }
    }

    func startLeadInRecord() {
        guard recording.phase == .idle else { return }
        if let track = project.selectedTrack, track.type == .instrumental {
            recording.statusMessage = "Select a vocal/audio track to record"
            return
        }
        if project.recordingTrackIndex == nil {
            recording.statusMessage = "Select a vocal/audio track to record"
            return
        }
        requestMicAndRecord(leadIn: true)
    }

    private func requestMicAndRecord(leadIn: Bool) {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.recording.configure(projectID: self.project.id)
                    self.recording.syncSelection(from: self.project)
                    if leadIn {
                        self.recording.startLeadInRecording(project: self.project)
                    } else {
                        self.recording.startRecording(project: self.project)
                    }
                    // Schedule exclude already ran inside beginLoopRecording / lead-in.
                    // Do not refresh again under a live mic.
                } else {
                    self.recording.statusMessage = "Microphone permission denied"
                }
            }
        }
    }

    func togglePlay() {
        if !(audio.isPlaying && recording.phase == .idle) && recording.phase == .idle {
            refreshClipPlaybackSchedule()
        }
        recording.togglePlay(project: project)
    }

    func returnToBeginning() {
        if recording.phase != .idle {
            recording.stop()
            applyInputMonitor()
            refreshClipPlaybackSchedule()
        } else if audio.isPlaying {
            audio.stopTransportPreservingPlayhead()
        }

        let region = project.currentRegion
        audio.setActiveRegion(region, resetPlayhead: false)
        let regionStart = region.startSeconds(bpm: project.bpm, timeSignature: project.timeSignature)
        let epsilon = 0.05
        if abs(audio.playheadSeconds - regionStart) <= epsilon {
            audio.seekPlayhead(to: 0, clampToLoop: false)
        } else {
            audio.seekPlayhead(to: regionStart, clampToLoop: false)
        }
    }

    /// Drag playhead scrubber on the ruler (does not change loop selection).
    func scrubPlayhead(toBeats beats: Double) {
        let clampedBeats = max(0, beats)
        let seconds = project.beatsToSeconds(clampedBeats)
        // Playhead is independent of the loop segment except during an active take.
        if recording.phase == .loopRecording, project.loopEnabled {
            audio.seekPlayhead(to: seconds, clampToLoop: true)
        } else {
            audio.scrub(to: seconds)
        }
    }

    func scrubPlayhead(toX x: CGFloat) {
        scrubPlayhead(toBeats: beats(atX: max(0, x)))
    }

    /// Nudge playhead to bar boundaries (touch scrub controls).
    /// Uses epsilon-tolerant bar indexing so seconds↔beats float error cannot wedge forward.
    func nudgePlayhead(byBars bars: Int) {
        guard bars != 0 else { return }
        let bpb = beatsPerBar
        guard bpb > 0 else { return }

        let currentBeats = project.secondsToBeats(playheadSeconds)
        // 11.999999 must count as bar index 3, not 2.
        let barIndex = Int(floor(currentBeats / bpb + 1e-6))
        let barStart = Double(barIndex) * bpb
        let onBarLine = abs(currentBeats - barStart) < 1e-3

        let targetIndex: Int
        if bars > 0 {
            targetIndex = barIndex + bars
        } else if onBarLine {
            targetIndex = barIndex + bars
        } else {
            // Mid-bar: -1 lands on this bar's downbeat; further steps go earlier.
            targetIndex = barIndex + bars + 1
        }

        let targetBeats = max(0, Double(targetIndex) * bpb)
        // Always free of the loop — bottom chevrons are disabled while recording.
        audio.scrub(to: project.beatsToSeconds(targetBeats))
        timelineInteraction.requestScrollPlayheadIntoView()
    }

    // MARK: - Import

    var importTypes: [UTType] {
        var types: [UTType] = [.wav, .mp3, .aiff, .mpeg4Audio]
        if let m4a = UTType(filenameExtension: "m4a") {
            types.append(m4a)
        }
        return types
    }

    func importInstrumental(url: URL) {
        isBusy = true
        defer { isBusy = false }
        do {
            try storage.ensureProjectFolders(for: project.id)
            // Ensure an instrumental track exists (e.g. after delete).
            if project.instrumentalTrack == nil {
                project.tracks.insert(
                    Track(name: "Instrumental", type: .instrumental, volume: 0.8),
                    at: 0
                )
            }
            let result = try storage.importInstrumental(from: url, projectID: project.id)
            if let idx = project.tracks.firstIndex(where: { $0.type == .instrumental }) {
                project.tracks[idx].audioRelativePath = result.relativePath
                let abs = storage.absoluteURL(for: result.relativePath, projectID: project.id)
                let peaks = TimelineManager.generateWaveformPeaks(url: abs, targetCount: 2000)
                project.tracks[idx].waveformPeaks = peaks
                audio.clearInstrumental()
                try audio.loadInstrumental(url: abs)
                var clip = AudioClip(
                    trackId: project.tracks[idx].id,
                    sourceRelativePath: result.relativePath,
                    sourceStartSeconds: 0,
                    sourceEndSeconds: result.duration,
                    timelineStartBeats: 0,
                    waveformPeaks: peaks
                )
                if let firstSound = TimelineManager.findFirstSoundTime(url: abs), firstSound > 0.01 {
                    clip.sourceStartSeconds = min(firstSound, max(0, result.duration - 0.05))
                    clip.waveformPeaks = TimelineManager.slicePeaks(
                        peaks,
                        sourceStart: clip.sourceStartSeconds,
                        sourceEnd: clip.sourceEndSeconds,
                        totalDuration: result.duration
                    )
                }
                project.tracks[idx].clips = [clip]
            }
            project.instrumentalDurationSeconds = result.duration
            project.selectionStartBar = 1
            project.selectionLengthBars = project.regionLength.rawValue
            applyAudioFromProject()
            autosave()
            showSetupSheet = true
            recording.statusMessage = "Instrumental imported"
        } catch {
            recording.statusMessage = error.localizedDescription
        }
    }

    func applyAudioFromProject() {
        audio.updateTransportContext(
            bpm: project.bpm,
            timeSignature: project.timeSignature,
            loopEnabled: project.loopEnabled,
            metronomeEnabled: project.metronomeEnabled
        )
        audio.setMasterVolume(project.masterVolume)
        // Don't yank the scrubbed playhead back to the loop start.
        audio.setActiveRegion(project.currentRegion, resetPlayhead: false)
        audio.setArrangementEndSeconds(RecordingManager.arrangementEndSeconds(for: project))
        if let resolved = storage.resolveInstrumentalURL(project: project) {
            repairInstrumentalPathsIfNeeded(relativePath: resolved.relativePath)
            do {
                try audio.loadInstrumental(url: resolved.url)
            } catch {
                audio.clearInstrumental()
                recording.statusMessage = "Instrumental failed to load"
                print("LoopFlow: loadInstrumental failed: \(error)")
            }
        } else if project.instrumentalTrack?.audioRelativePath != nil
                    || project.instrumentalTrack?.clips.first?.sourceRelativePath != nil
                    || !(project.instrumentalTrack?.waveformPeaks.isEmpty ?? true) {
            audio.clearInstrumental()
            recording.statusMessage = "Instrumental file missing — re-import"
        } else {
            audio.clearInstrumental()
        }
        if let inst = project.instrumentalTrack {
            audio.setInstrumentalVolume(inst.isMuted ? 0 : inst.volume)
        } else {
            audio.setInstrumentalVolume(0)
        }
        refreshInstrumentalMapping()
        refreshClipPlaybackSchedule()
        applyInputMonitor()
    }

    /// Persist a recovered instrumental relative path onto the track and its clip.
    private func repairInstrumentalPathsIfNeeded(relativePath: String) {
        guard let trackIdx = project.tracks.firstIndex(where: { $0.type == .instrumental }) else { return }
        var didRepair = false
        if project.tracks[trackIdx].audioRelativePath != relativePath {
            project.tracks[trackIdx].audioRelativePath = relativePath
            didRepair = true
        }
        if let clipIdx = project.tracks[trackIdx].clips.indices.first,
           project.tracks[trackIdx].clips[clipIdx].sourceRelativePath != relativePath {
            project.tracks[trackIdx].clips[clipIdx].sourceRelativePath = relativePath
            didRepair = true
        }
        if didRepair {
            autosave()
        }
    }

    /// Schedules unmuted vocal/audio clips for live playback.
    func refreshClipPlaybackSchedule() {
        let recordingTrackId: UUID? = {
            // Count-in + armed loop record: never play back the track being recorded over.
            // Lead-in keeps the previous take audible until punch-in.
            guard recording.phase == .countIn || recording.phase == .loopRecording,
                  let idx = project.recordingTrackIndex else { return nil }
            return project.tracks[idx].id
        }()
        var clips: [ScheduledClip] = []
        for track in project.tracks where track.type != .instrumental {
            guard !track.isMuted else { continue }
            // While recording, don't play back clips on the active record track
            // (input monitor + instrumental only — avoids hearing the existing kept take).
            if let recordingTrackId, track.id == recordingTrackId { continue }
            for clip in track.clips where !clip.isMuted {
                let url = storage.absoluteURL(for: clip.sourceRelativePath, projectID: project.id)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                clips.append(
                    ScheduledClip(
                        url: url,
                        sourceStartSeconds: clip.sourceStartSeconds,
                        sourceEndSeconds: clip.sourceEndSeconds,
                        timelineStartSeconds: project.beatsToSeconds(clip.timelineStartBeats),
                        gain: track.volume * clip.gain
                    )
                )
            }
        }
        audio.setClipSchedule(clips)
    }

    /// Updates playback mapping for the instrumental clip without resetting the playhead.
    func refreshInstrumentalMapping() {
        guard let clip = activeInstrumentalClip else {
            audio.clearInstrumentalClipMapping()
            return
        }
        audio.setInstrumentalClipMapping(
            sourceStartSeconds: clip.sourceStartSeconds,
            sourceEndSeconds: clip.sourceEndSeconds,
            timelineStartSeconds: project.beatsToSeconds(clip.timelineStartBeats)
        )
    }

    // MARK: - Instrumental align

    /// Prefer the selected instrumental clip, else the earliest unmuted one on the timeline.
    var instrumentalClip: AudioClip? { activeInstrumentalClip }

    private var activeInstrumentalClip: AudioClip? {
        guard let inst = project.instrumentalTrack else { return nil }
        let unmuted = inst.clips.filter { !$0.isMuted }
        guard !unmuted.isEmpty else { return nil }
        if let selectedId = timelineInteraction.selectedClipId,
           let selected = unmuted.first(where: { $0.id == selectedId }) {
            return selected
        }
        return unmuted.min(by: { $0.timelineStartBeats < $1.timelineStartBeats })
    }

    /// Skip leading silence so audible content starts at the clip's timeline position (usually bar 1).
    func alignInstrumentalToFirstSound() {
        guard let trackIdx = project.tracks.firstIndex(where: { $0.type == .instrumental }),
              let clipIdx = project.tracks[trackIdx].clips.indices.first,
              let resolved = storage.resolveInstrumentalURL(project: project) else {
            recording.statusMessage = "No instrumental"
            return
        }
        repairInstrumentalPathsIfNeeded(relativePath: resolved.relativePath)
        let url = resolved.url
        guard let firstSound = TimelineManager.findFirstSoundTime(url: url) else {
            recording.statusMessage = "No sound found"
            return
        }
        pushUndo()
        var clip = project.tracks[trackIdx].clips[clipIdx]
        let fileDuration = max(project.instrumentalDurationSeconds, clip.sourceEndSeconds)
        clip.sourceStartSeconds = min(max(0, firstSound), max(0, fileDuration - 0.05))
        if clip.sourceEndSeconds <= clip.sourceStartSeconds {
            clip.sourceEndSeconds = fileDuration
        }
        let fullPeaks = project.tracks[trackIdx].waveformPeaks
        clip.waveformPeaks = TimelineManager.slicePeaks(
            fullPeaks.isEmpty ? clip.waveformPeaks : fullPeaks,
            sourceStart: clip.sourceStartSeconds,
            sourceEnd: clip.sourceEndSeconds,
            totalDuration: fileDuration
        )
        project.tracks[trackIdx].clips[clipIdx] = clip
        refreshInstrumentalMapping()
        recording.statusMessage = String(format: "Aligned (skipped %.2fs)", firstSound)
        autosave()
    }

    /// Restore instrumental clip to the full file starting at bar 1.
    func resetInstrumentalClipBounds() {
        guard let trackIdx = project.tracks.firstIndex(where: { $0.type == .instrumental }),
              let resolved = storage.resolveInstrumentalURL(project: project) else {
            recording.statusMessage = "No instrumental"
            return
        }
        repairInstrumentalPathsIfNeeded(relativePath: resolved.relativePath)
        pushUndo()
        let duration = project.instrumentalDurationSeconds
        let peaks = project.tracks[trackIdx].waveformPeaks
        if project.tracks[trackIdx].clips.isEmpty {
            project.tracks[trackIdx].clips = [
                AudioClip(
                    trackId: project.tracks[trackIdx].id,
                    sourceRelativePath: resolved.relativePath,
                    sourceStartSeconds: 0,
                    sourceEndSeconds: duration,
                    timelineStartBeats: 0,
                    waveformPeaks: peaks
                )
            ]
        } else {
            var clip = project.tracks[trackIdx].clips[0]
            clip.sourceRelativePath = resolved.relativePath
            clip.sourceStartSeconds = 0
            clip.sourceEndSeconds = duration
            clip.timelineStartBeats = 0
            clip.waveformPeaks = peaks
            project.tracks[trackIdx].clips[0] = clip
        }
        refreshInstrumentalMapping()
        recording.statusMessage = "Reset clip bounds"
        autosave()
    }

    /// Nudge instrumental in-point without moving its timeline start (keeps bar 1 fixed).
    func nudgeInstrumentalSourceStart(deltaSeconds: Double) {
        guard let trackIdx = project.tracks.firstIndex(where: { $0.type == .instrumental }),
              !project.tracks[trackIdx].clips.isEmpty else { return }
        pushUndo()
        var clip = project.tracks[trackIdx].clips[0]
        let fileDuration = max(project.instrumentalDurationSeconds, clip.sourceEndSeconds)
        let next = min(max(0, clip.sourceStartSeconds + deltaSeconds), max(0, clip.sourceEndSeconds - 0.05))
        clip.sourceStartSeconds = next
        let fullPeaks = project.tracks[trackIdx].waveformPeaks
        clip.waveformPeaks = TimelineManager.slicePeaks(
            fullPeaks.isEmpty ? clip.waveformPeaks : fullPeaks,
            sourceStart: clip.sourceStartSeconds,
            sourceEnd: clip.sourceEndSeconds,
            totalDuration: fileDuration
        )
        project.tracks[trackIdx].clips[0] = clip
        refreshInstrumentalMapping()
        autosave()
    }

    func nudgeInstrumentalSourceEnd(deltaSeconds: Double) {
        guard let trackIdx = project.tracks.firstIndex(where: { $0.type == .instrumental }),
              !project.tracks[trackIdx].clips.isEmpty else { return }
        pushUndo()
        var clip = project.tracks[trackIdx].clips[0]
        let fileDuration = max(project.instrumentalDurationSeconds, clip.sourceEndSeconds)
        let next = min(max(clip.sourceStartSeconds + 0.05, clip.sourceEndSeconds + deltaSeconds), fileDuration)
        clip.sourceEndSeconds = next
        let fullPeaks = project.tracks[trackIdx].waveformPeaks
        clip.waveformPeaks = TimelineManager.slicePeaks(
            fullPeaks.isEmpty ? clip.waveformPeaks : fullPeaks,
            sourceStart: clip.sourceStartSeconds,
            sourceEnd: clip.sourceEndSeconds,
            totalDuration: fileDuration
        )
        project.tracks[trackIdx].clips[0] = clip
        refreshInstrumentalMapping()
        autosave()
    }

    // MARK: - Tracks

    func addTrack() {
        pushUndo()
        let n = project.tracks.filter { $0.type == .audio }.count + 1
        let track = Track(name: "Track \(n)", type: .audio)
        project.tracks.append(track)
        project.selectedTrackId = track.id
        autosave()
    }

    func updateTrack(_ track: Track) {
        guard let idx = project.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        var next = track
        // Keep exclusive monitor flag consistent if UI flipped the binding directly.
        if next.inputMonitorEnabled {
            for i in project.tracks.indices where project.tracks[i].id != next.id {
                project.tracks[i].inputMonitorEnabled = false
            }
        }
        project.tracks[idx] = next
        if next.type == .instrumental {
            audio.setInstrumentalVolume(next.isMuted ? 0 : next.volume)
        }
        applyInputMonitor()
        refreshClipPlaybackSchedule()
        autosave()
    }

    func setInputMonitor(trackId: UUID, enabled: Bool) {
        guard let idx = project.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        let track = project.tracks[idx]
        guard track.type == .vocal || track.type == .audio else { return }

        if enabled {
            for i in project.tracks.indices {
                project.tracks[i].inputMonitorEnabled = (project.tracks[i].id == trackId)
            }
            requestMicForMonitor()
        } else {
            project.tracks[idx].inputMonitorEnabled = false
            applyInputMonitor()
            autosave()
        }
    }

    private func requestMicForMonitor() {
        let session = AVAudioSession.sharedInstance()
        let alreadyGranted = session.recordPermission == .granted
        let apply: (Bool) -> Void = { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.applyInputMonitor()
                    if self.audio.monitorBlockedByRoute {
                        self.recording.statusMessage = "Monitoring needs headphones"
                    } else if let name = self.project.tracks.first(where: { $0.inputMonitorEnabled })?.name {
                        self.recording.statusMessage = "Monitoring \(name) — speak to test"
                    }
                } else {
                    for i in self.project.tracks.indices {
                        self.project.tracks[i].inputMonitorEnabled = false
                    }
                    self.applyInputMonitor()
                    self.recording.statusMessage = "Microphone permission denied"
                }
                self.autosave()
            }
        }
        if alreadyGranted {
            apply(true)
        } else {
            session.requestRecordPermission { granted in
                apply(granted)
            }
        }
    }

    /// Applies live mic monitor based on track I flag, mute, volume, and headphone/BT route.
    func applyInputMonitor() {
        let monitoringTrack = project.tracks.first(where: {
            $0.inputMonitorEnabled && ($0.type == .vocal || $0.type == .audio)
        })
        audio.setInputMeteringEnabled(monitoringTrack != nil)
        guard let track = monitoringTrack else {
            audio.setInputMonitor(enabled: false, volume: 0)
            return
        }
        audio.setInputMonitor(enabled: !track.isMuted, volume: track.volume)
    }

    func selectTrack(id: UUID) {
        guard project.tracks.contains(where: { $0.id == id }) else { return }
        project.selectedTrackId = id
        // Clear clip selection when changing track via header/lane (not via clip tap)
        autosave()
    }

    func deleteTrack(id: UUID) {
        guard project.tracks.count > 1 else {
            recording.statusMessage = "Can't delete the last track"
            return
        }
        guard let idx = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        let removed = project.tracks.remove(at: idx)
        if timelineInteraction.selectedClipId != nil,
           removed.clips.contains(where: { $0.id == timelineInteraction.selectedClipId }) {
            selectClip(nil)
        }
        if project.selectedTrackId == id {
            project.ensureSelectedTrack()
        }
        if removed.inputMonitorEnabled {
            applyInputMonitor()
        }
        if removed.type == .instrumental {
            project.instrumentalDurationSeconds = 0
            audio.clearInstrumental()
            // Keep an empty instrumental lane so Import/Replace still has a target.
            if project.instrumentalTrack == nil {
                project.tracks.insert(
                    Track(name: "Instrumental", type: .instrumental, volume: 0.8),
                    at: 0
                )
            }
            recording.statusMessage = "Instrumental removed"
        } else {
            recording.statusMessage = "Deleted \(removed.name)"
        }
        refreshClipPlaybackSchedule()
        applyAudioFromProject()
        autosave()
    }

    /// Remove instrumental audio/clips but keep the track (for replace via Import).
    func clearInstrumental() {
        guard let idx = project.tracks.firstIndex(where: { $0.type == .instrumental }) else {
            audio.clearInstrumental()
            return
        }
        pushUndo()
        recording.stop()
        audio.stop()
        project.tracks[idx].audioRelativePath = nil
        project.tracks[idx].clips = []
        project.tracks[idx].waveformPeaks = []
        project.tracks[idx].takes = []
        project.instrumentalDurationSeconds = 0
        audio.clearInstrumental()
        selectClip(nil)
        recording.statusMessage = "Instrumental cleared — import a new one"
        applyAudioFromProject()
        autosave()
        showImporter = true
    }

    /// Start a fresh session (stops transport, clears engine, opens setup).
    func startNewProject() {
        recording.stop()
        audio.stop()
        audio.clearInstrumental()
        audio.setClipSchedule([])
        selectClip(nil)
        clipboard = nil
        let fresh = LoopFlowProject()
        do {
            try storage.ensureProjectFolders(for: fresh.id)
            try storage.save(fresh)
            project = fresh
            activateLoadedProject()
            recording.statusMessage = "New session"
            isInStudio = true
            showSetupSheet = true
            refreshSessionSummaries()
        } catch {
            recording.statusMessage = error.localizedDescription
        }
    }

    func openProject(id: UUID) {
        recording.stop()
        audio.stop()
        audio.clearInstrumental()
        audio.setClipSchedule([])
        selectClip(nil)
        clipboard = nil
        do {
            var loaded = try storage.load(projectID: id)
            loaded.ensureClipsMigrated()
            loaded.ensureSelectedTrack()
            project = loaded
            activateLoadedProject()
            try storage.save(project)
            recording.statusMessage = "Opened"
            isInStudio = true
            showSetupSheet = project.instrumentalTrack?.audioRelativePath == nil
            refreshSessionSummaries()
        } catch {
            recording.statusMessage = error.localizedDescription
        }
    }

    func closeToLibrary() {
        save()
        recording.stop()
        audio.stop()
        showSetupSheet = false
        showSettings = false
        showExport = false
        isInStudio = false
        refreshSessionSummaries()
    }

    func deleteProject(id: UUID) {
        let deletingCurrent = project.id == id
        if deletingCurrent {
            recording.stop()
            audio.stop()
            audio.clearInstrumental()
            audio.setClipSchedule([])
            selectClip(nil)
            clipboard = nil
            isInStudio = false
            showSetupSheet = false
        }
        do {
            try storage.delete(projectID: id)
            if deletingCurrent {
                if let next = storage.listProjectSummaries().first {
                    var loaded = try storage.load(projectID: next.id)
                    loaded.ensureClipsMigrated()
                    loaded.ensureSelectedTrack()
                    project = loaded
                    activateLoadedProject()
                } else {
                    project = LoopFlowProject()
                    editHistory.clear()
                    audio.clearInstrumental()
                    audio.setClipSchedule([])
                }
            }
            refreshSessionSummaries()
        } catch {
            recording.statusMessage = error.localizedDescription
        }
    }

    func refreshSessionSummaries() {
        sessionSummaries = storage.listProjectSummaries()
    }

    private func activateLoadedProject() {
        project.ensureClipsMigrated()
        project.ensureSelectedTrack()
        recording.configure(projectID: project.id)
        recording.syncSelection(from: project)
        controller.updateMappings(project.keyMappings)
        editHistory.clear()
        applyAudioFromProject()
        applyInputMonitor()
    }

    // MARK: - Bar selection

    /// Move the loop window to `bar` while keeping length locked to `regionLength`.
    /// - Parameter commit: When false, only updates selection UI (for live drag). When true, applies transport + autosave.
    func moveLoopSelection(toStartBar bar: Int, commit: Bool = true) {
        let length = project.regionLength.rawValue
        project.selectionLengthBars = length
        let maxStart = max(1, project.totalBars - length + 1)
        project.selectionStartBar = min(max(1, bar), maxStart)
        recording.syncSelection(from: project)
        if commit {
            applyAudioFromProject()
            autosave()
        }
    }

    /// Finish a loop-band drag: apply transport to the current selection and persist.
    func endLoopSelectionDrag() {
        recording.syncSelection(from: project)
        applyAudioFromProject()
        autosave()
    }

    func selectBar(_ bar: Int, length: Int? = nil) {
        // Length is always the project preset (ignore freeform length).
        _ = length
        moveLoopSelection(toStartBar: bar)
    }

    func selectBarRange(from start: Int, to end: Int) {
        // Freeform range ignored — move window so start tracks the drag, length stays preset.
        _ = end
        moveLoopSelection(toStartBar: start)
    }

    func applyRegionPreset(_ length: RegionLength) {
        pushUndo()
        project.applySelectionPreset(length)
        recording.syncSelection(from: project)
        applyAudioFromProject()
        autosave()
    }

    func setLoopEnabled(_ enabled: Bool) {
        project.loopEnabled = enabled
        if enabled {
            // Restore preset-length selection when loop chrome returns
            moveLoopSelection(toStartBar: project.selectionStartBar)
        } else {
            applyAudioFromProject()
            autosave()
        }
    }

    // MARK: - Zoom

    func setPixelsPerBar(_ value: CGFloat, anchorBeats: Double? = nil) {
        let clamped = min(
            TimelineInteractionState.maxPixelsPerBar,
            max(TimelineInteractionState.minPixelsPerBar, value)
        )
        pixelsPerBar = clamped
        timelineInteraction.pinchAnchorBeats = anchorBeats
    }

    func zoomIn() { setPixelsPerBar(pixelsPerBar + 16) }
    func zoomOut() { setPixelsPerBar(pixelsPerBar - 16) }

    var beatsPerBar: Double { Double(project.timeSignature.beatsPerBar) }

    func pixelsPerBeat() -> CGFloat {
        pixelsPerBar / CGFloat(max(project.timeSignature.beatsPerBar, 1))
    }

    func xPosition(forBeats beats: Double) -> CGFloat {
        CGFloat(beats) * pixelsPerBeat()
    }

    func beats(atX x: CGFloat) -> Double {
        Double(x / max(pixelsPerBeat(), 0.001))
    }

    func bar(atX x: CGFloat) -> Int {
        let beats = beats(atX: x)
        return max(1, Int(beats / beatsPerBar) + 1)
    }

    /// Grid subdivision level from zoom.
    /// 0 = bars, 1 = beats, 4 = quarter-beats (16ths in 4/4).
    var gridSubdivision: Int {
        if pixelsPerBar >= 140 { return 4 }
        if pixelsPerBar >= 72 { return 1 }
        return 0
    }

    /// Snap step in beats matching the visible grid at the current zoom.
    var snapStepBeats: Double {
        switch gridSubdivision {
        case 4: return 0.25
        case 1: return 1
        default: return beatsPerBar
        }
    }

    func snapBeats(_ beats: Double) -> Double {
        project.snapBeats(beats, stepBeats: snapStepBeats)
    }

    func downsamplePeaks(_ peaks: [Float], forWidth width: CGFloat) -> [Float] {
        let target = max(1, Int(width / 2))
        guard peaks.count > target, target > 0 else { return peaks }
        let bucket = peaks.count / target
        var out: [Float] = []
        out.reserveCapacity(target)
        var i = 0
        while i < peaks.count {
            let end = min(i + bucket, peaks.count)
            var m: Float = 0
            for j in i..<end { m = max(m, peaks[j]) }
            out.append(m)
            i = end
        }
        return out
    }

    // MARK: - Clip lookup / selection

    func clip(id: UUID) -> (trackIndex: Int, clipIndex: Int, clip: AudioClip)? {
        for ti in project.tracks.indices {
            if let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == id }) {
                return (ti, ci, project.tracks[ti].clips[ci])
            }
        }
        return nil
    }

    var selectedClip: AudioClip? {
        guard let id = timelineInteraction.selectedClipId else { return nil }
        return clip(id: id)?.clip
    }

    func selectClip(_ id: UUID?, presentSheet: Bool = false) {
        let anchor = presentSheet ? project.secondsToBeats(playheadSeconds) : nil
        timelineInteraction.selectClip(id, presentSheet: presentSheet, splitAnchorBeats: anchor)
        if let id, let found = clip(id: id) {
            project.selectedTrackId = found.clip.trackId
        }
    }

    // MARK: - Clip edits

    func pushUndo() {
        editHistory.push(project)
    }

    func performUndo() {
        guard let previous = editHistory.undo(current: project) else {
            recording.statusMessage = "Nothing to undo"
            return
        }
        project = previous
        applyAudioFromProject()
        recording.statusMessage = "Undo — restored previous clip"
        autosave()
    }

    func performRedo() {
        guard let next = editHistory.redo(current: project) else {
            recording.statusMessage = "Nothing to redo"
            return
        }
        project = next
        applyAudioFromProject()
        recording.statusMessage = "Redo"
        autosave()
    }

    private func updateSelectedClip(_ mutate: (inout AudioClip) -> Void) {
        guard let id = timelineInteraction.selectedClipId,
              let found = clip(id: id) else { return }
        var c = found.clip
        mutate(&c)
        project.tracks[found.trackIndex].clips[found.clipIndex] = c
        if project.tracks[found.trackIndex].type == .instrumental {
            refreshInstrumentalMapping()
        } else {
            refreshClipPlaybackSchedule()
        }
        autosave()
    }

    func moveSelectedClip(toBeats beats: Double) {
        pushUndo()
        let snapped = snapBeats(max(0, beats))
        snapIndicatorBeats = snapped
        updateSelectedClip { $0.timelineStartBeats = snapped }
    }

    func trimSelectedClip(startDeltaSeconds: Double = 0, endDeltaSeconds: Double = 0) {
        pushUndo()
        updateSelectedClip { clip in
            clip.sourceStartSeconds = max(0, clip.sourceStartSeconds + startDeltaSeconds)
            clip.sourceEndSeconds = max(clip.sourceStartSeconds + 0.05, clip.sourceEndSeconds + endDeltaSeconds)
            if startDeltaSeconds != 0 {
                let beatDelta = project.secondsToBeats(startDeltaSeconds)
                clip.timelineStartBeats += beatDelta
            }
        }
    }

    func nudgeTrimStart() {
        trimSelectedClip(startDeltaSeconds: project.secondsPerBeat)
    }

    func nudgeTrimEnd() {
        trimSelectedClip(endDeltaSeconds: -project.secondsPerBeat)
    }

    func splitSelectedClipAtPlayhead() {
        guard let id = timelineInteraction.selectedClipId,
              let found = clip(id: id) else { return }
        let clip = found.clip
        // Prefer live playhead; fall back to anchor captured when the clip was selected.
        var splitBeats = project.secondsToBeats(playheadSeconds)
        if let anchor = timelineInteraction.splitAnchorBeats {
            let start = clip.timelineStartBeats
            let end = clip.timelineEndBeats(bpm: project.bpm)
            let playheadInside = splitBeats > start + 0.01 && splitBeats < end - 0.01
            if !playheadInside {
                splitBeats = anchor
            }
        }
        if project.snapEnabled {
            splitBeats = project.snapBeats(splitBeats, stepBeats: snapStepBeats)
        }
        let start = clip.timelineStartBeats
        let end = clip.timelineEndBeats(bpm: project.bpm)
        guard splitBeats > start + 0.01, splitBeats < end - 0.01 else {
            recording.statusMessage = "Move playhead onto the clip, then Split"
            return
        }
        pushUndo()
        let sourceDuration = max(0.05, clip.sourceEndSeconds - clip.sourceStartSeconds)
        let timelineDuration = max(0.05, end - start)
        let ratio = (splitBeats - start) / timelineDuration
        let splitSource = clip.sourceStartSeconds + sourceDuration * ratio

        var left = clip
        left.sourceEndSeconds = splitSource
        var right = clip
        right.id = UUID()
        right.sourceStartSeconds = splitSource
        right.timelineStartBeats = splitBeats

        if !clip.waveformPeaks.isEmpty {
            left.waveformPeaks = TimelineManager.slicePeaks(
                clip.waveformPeaks,
                sourceStart: left.sourceStartSeconds - clip.sourceStartSeconds,
                sourceEnd: left.sourceEndSeconds - clip.sourceStartSeconds,
                totalDuration: sourceDuration
            )
            right.waveformPeaks = TimelineManager.slicePeaks(
                clip.waveformPeaks,
                sourceStart: right.sourceStartSeconds - clip.sourceStartSeconds,
                sourceEnd: right.sourceEndSeconds - clip.sourceStartSeconds,
                totalDuration: sourceDuration
            )
        }

        project.tracks[found.trackIndex].clips[found.clipIndex] = left
        project.tracks[found.trackIndex].clips.append(right)
        if project.tracks[found.trackIndex].type == .instrumental {
            refreshInstrumentalMapping()
        } else {
            refreshClipPlaybackSchedule()
        }
        // Select the new right-hand clip and open its edit menu.
        selectClip(right.id, presentSheet: true)
        recording.statusMessage = "Split at playhead"
        autosave()
    }

    func copySelectedClip() {
        guard let clip = selectedClip else { return }
        clipboard = ClipClipboard(clip: clip, originalTimelineStartBeats: clip.timelineStartBeats)
        recording.statusMessage = "Copied"
    }

    func cutSelectedClip() {
        copySelectedClip()
        deleteSelectedClip()
    }

    func pasteClipboard() {
        guard var payload = clipboard else {
            recording.statusMessage = "Clipboard empty"
            return
        }
        pushUndo()
        let pasteBeats: Double
        if timelineInteraction.selectedClipId == nil {
            pasteBeats = project.barToBeats(project.selectionStartBar)
        } else {
            pasteBeats = project.secondsToBeats(playheadSeconds)
        }
        var newClip = payload.clip
        newClip.id = UUID()
        newClip.timelineStartBeats = snapBeats(pasteBeats)
        // Prefer vocal track if original gone; else first matching track id or vocal
        let trackIdx = project.tracks.firstIndex(where: { $0.id == newClip.trackId })
            ?? project.vocalTrackIndex
            ?? 0
        newClip.trackId = project.tracks[trackIdx].id
        project.tracks[trackIdx].clips.append(newClip)
        selectClip(newClip.id, presentSheet: true)
        recording.statusMessage = "Pasted"
        autosave()
    }

    func duplicateSelectedClip() {
        guard let clip = selectedClip else { return }
        pushUndo()
        var copy = clip
        copy.id = UUID()
        copy.timelineStartBeats = snapBeats(clip.timelineEndBeats(bpm: project.bpm))
        guard let found = self.clip(id: clip.id) else { return }
        project.tracks[found.trackIndex].clips.append(copy)
        selectClip(copy.id, presentSheet: true)
        recording.statusMessage = "Duplicated"
        autosave()
    }

    func deleteSelectedClip() {
        guard let id = timelineInteraction.selectedClipId,
              let found = clip(id: id) else { return }
        pushUndo()
        let path = found.clip.sourceRelativePath
        let trackIdx = found.trackIndex
        let trackType = project.tracks[trackIdx].type
        project.tracks[trackIdx].takes.removeAll { $0.relativePath == path }
        project.tracks[trackIdx].removeClip(id: id)
        selectClip(nil)

        // Split shares one file across halves — only delete media when nothing references it.
        let stillReferenced = project.tracks.contains { track in
            track.clips.contains { $0.sourceRelativePath == path }
        }
        refreshClipPlaybackSchedule()
        if !stillReferenced {
            let url = storage.absoluteURL(for: path, projectID: project.id)
            try? FileManager.default.removeItem(at: url)
        }

        if trackType == .instrumental {
            if project.tracks[trackIdx].clips.isEmpty {
                project.tracks[trackIdx].audioRelativePath = nil
                project.tracks[trackIdx].waveformPeaks = []
                project.instrumentalDurationSeconds = 0
                audio.clearInstrumental()
            } else {
                refreshInstrumentalMapping()
            }
        }

        recording.statusMessage = "Deleted"
        autosave()
    }

    func toggleMuteSelectedClip() {
        pushUndo()
        updateSelectedClip { $0.isMuted.toggle() }
    }

    func toggleLoopSelectedClip() {
        pushUndo()
        updateSelectedClip { $0.isLooping.toggle() }
    }

    func toggleSnap() {
        project.snapEnabled.toggle()
        autosave()
    }

    // MARK: - Persistence

    func save() {
        do {
            project.keyMappings = controller.mappings
            try storage.save(project)
            recording.statusMessage = "Saved"
        } catch {
            recording.statusMessage = error.localizedDescription
        }
    }

    func autosave() {
        project.keyMappings = controller.mappings
        try? storage.save(project)
    }

    func syncMappingsFromController() {
        project.keyMappings = controller.mappings
        autosave()
    }

    // MARK: - Export

    func export(_ kind: ExportKind) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let urls = try await exporter.export(kind, project: project)
            exportMessage = "Exported \(kind.displayName): \(urls.map(\.lastPathComponent).joined(separator: ", "))"
            share(urls: urls)
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    private func share(urls: [URL]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
        }
        root.present(vc, animated: true)
    }

    // MARK: - Timeline helpers

    var playheadSeconds: Double { audio.playheadSeconds }

    /// Arrange timeline length in bars — grows with the playhead so scrubbing past short content isn't clipped.
    var visibleTimelineBars: Int {
        let bpb = max(beatsPerBar, 1)
        let playheadBar = Int(floor(project.secondsToBeats(playheadSeconds) / bpb)) + 1
        let pad = 8
        return max(project.totalBars, playheadBar + pad, project.selectionEndBar + pad, 16)
    }

    var timeDisplay: String {
        TimelineManager.timeString(seconds: playheadSeconds)
    }
}
