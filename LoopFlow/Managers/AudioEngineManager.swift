import Foundation
@preconcurrency import AVFoundation
import UIKit
import QuartzCore

/// A non-instrumental clip ready for live playback scheduling.
struct ScheduledClip: Equatable {
    var url: URL
    var sourceStartSeconds: Double
    var sourceEndSeconds: Double
    var timelineStartSeconds: Double
    var gain: Float
}

@MainActor
final class AudioEngineManager: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isRecording = false
    @Published private(set) var isCountingIn = false
    @Published private(set) var playheadSeconds: Double = 0
    /// True when the user wants monitoring but the current route is not headphones/BT.
    @Published private(set) var monitorBlockedByRoute = false
    @Published private(set) var isHeadphoneOrBluetoothOutput = false
    /// Smoothed mic input level 0…1 for UI metering.
    @Published private(set) var inputLevel: Float = 0
    @Published var errorMessage: String?

    /// Called when the audio route changes (headphones plugged/unplugged, BT connect, etc.).
    var onRouteChange: (() -> Void)?

    private var desiredMonitorEnabled = false
    private var desiredMonitorVolume: Float = 0
    private var wantsInputMetering = false
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    let engine = AVAudioEngine()
    private let instrumentalPlayer = AVAudioPlayerNode()
    private let metronomePlayer = AVAudioPlayerNode()
    /// Splits mic for hardware monitor + meter/record tap (tap here, not on inputNode).
    private let micSplitter = AVAudioMixerNode()
    private let vocalMonitorMixer = AVAudioMixerNode()
    private let instrumentalMixer = AVAudioMixerNode()
    private let metronomeMixer = AVAudioMixerNode()
    private let clipPlaybackMixer = AVAudioMixerNode()
    private let clipPlayers: [AVAudioPlayerNode] = (0..<8).map { _ in AVAudioPlayerNode() }

    private var instrumentalFile: AVAudioFile?
    /// Path of the currently loaded instrumental (skip reload when unchanged).
    private var instrumentalLoadedURL: URL?
    private var scheduledClips: [ScheduledClip] = []
    private var clipFileCache: [URL: AVAudioFile] = [:]
    /// Non-destructive instrumental window mapped onto the timeline.
    private var instrumentalSourceStartSeconds: Double = 0
    private var instrumentalSourceEndSeconds: Double = 0
    private var instrumentalTimelineStartSeconds: Double = 0
    private var instrumentalClipMappingEnabled = false
    private var displayLink: CADisplayLink?
    private var regionStartSeconds: Double = 0
    private var regionDurationSeconds: Double = 0
    /// End of arrangement content for non-loop playback (seconds).
    private var arrangementEndSeconds: Double = 0
    private var loopEnabled = true
    private var playbackStartedHostTime: UInt64?
    private var playbackStartedOffset: Double = 0

    private var recordingFile: AVAudioFile?
    /// Nonisolated handle for the audio-thread tap write (mirrors `recordingFile`).
    private nonisolated(unsafe) var recordingFileForTap: AVAudioFile?
    private nonisolated(unsafe) var recordingConverter: AVAudioConverter?
    private nonisolated(unsafe) var recordingWriteFormat: AVAudioFormat?
    /// Gate so close/rotate can finalize the WAV before the tap writes again.
    private nonisolated(unsafe) var recordingWriteEnabled = false
    private var inputTapInstalled = false
    /// Sample rate of the current `inputNode → micSplitter` connection (0 = not connected).
    private var micPathSampleRate: Double = 0
    /// Last applied session config (skip no-op reconfigs that trigger route rebuilds).
    private var configuredSessionMode: AVAudioSession.Mode?
    private var configuredIOBufferDuration: TimeInterval = -1
    private var configuredForCapture = false
    private var lastRouteReconnectTime: CFAbsoluteTime = 0
    private var onLoopBoundary: (() -> Void)?
    private var onCountInFinished: (() -> Void)?

    private var bpm: Double = 120
    private var timeSignature = TimeSignature.fourFour
    private var metronomeEnabled = true
    private var sampleRate: Double = 44_100

    private var countInBeatsRemaining = 0
    private var lastMetronomeBeat: Int = -1
    /// When true, the next host-time crossing of region end may fire a loop boundary.
    private var loopBoundaryArmed = false

    /// Round-trip I/O latency for aligning recorded takes to what was heard.
    /// Prefer engine presentation latencies (session figures often under-report through AVAudioEngine).
    var roundTripLatencySeconds: TimeInterval {
        let session = AVAudioSession.sharedInstance()
        let input = max(session.inputLatency, engine.inputNode.presentationLatency)
        let output = max(session.outputLatency, engine.outputNode.presentationLatency)
        // Two IO buffers cover player/tap quantum often missing from session-only figures.
        return max(0, input + output + (2 * session.ioBufferDuration))
    }

    /// User fine-tune from Settings (milliseconds → seconds). Positive = trim more (fix late takes).
    var recordingLatencyOffsetSeconds: TimeInterval {
        Double(UserDefaults.standard.integer(forKey: Self.recordingLatencyOffsetKey)) / 1000.0
    }

    static let recordingLatencyOffsetKey = "recordingLatencyOffsetMilliseconds"

    /// Latency frozen when mic writes armed for the current recording pass.
    private(set) var activeRecordingLatencySeconds: TimeInterval = 0

    init() {
        setupGraph()
        refreshRouteState()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleRouteChange()
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        }
    }

    deinit {
        displayLink?.invalidate()
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    private func setupGraph() {
        engine.attach(instrumentalPlayer)
        engine.attach(metronomePlayer)
        engine.attach(micSplitter)
        engine.attach(vocalMonitorMixer)
        engine.attach(instrumentalMixer)
        engine.attach(metronomeMixer)
        engine.attach(clipPlaybackMixer)
        for player in clipPlayers {
            engine.attach(player)
            engine.connect(player, to: clipPlaybackMixer, format: nil)
        }

        let main = engine.mainMixerNode

        engine.connect(instrumentalPlayer, to: instrumentalMixer, format: nil)
        engine.connect(instrumentalMixer, to: main, format: nil)
        engine.connect(metronomePlayer, to: metronomeMixer, format: nil)
        engine.connect(metronomeMixer, to: main, format: nil)
        engine.connect(clipPlaybackMixer, to: main, format: nil)
        // Hardware monitor: input → micSplitter → vocalMonitorMixer → main
        // (Tap micSplitter for meter/record — tapping inputNode often silences passthrough.)
        engine.connect(micSplitter, to: vocalMonitorMixer, format: nil)
        engine.connect(vocalMonitorMixer, to: main, format: nil)
        vocalMonitorMixer.outputVolume = 0
    }

    /// Ensure session + engine are ready to receive mic input. Touching input creates the IO unit.
    private func prepareInputCapture() {
        _ = engine.inputNode.inputFormat(forBus: 0)
    }

    /// Connect `inputNode → micSplitter` with the current hardware format (lazy, rebuild on rate change).
    @discardableResult
    private func connectMicPathIfNeeded() -> AVAudioFormat? {
        prepareInputCapture()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }

        if abs(micPathSampleRate - format.sampleRate) < 1, micPathSampleRate > 0 {
            return format
        }

        let wasRunning = engine.isRunning
        if inputTapInstalled {
            micSplitter.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        engine.disconnectNodeOutput(input)
        engine.disconnectNodeOutput(micSplitter)
        engine.connect(input, to: micSplitter, format: format)
        engine.connect(micSplitter, to: vocalMonitorMixer, format: format)
        micPathSampleRate = format.sampleRate
        if wasRunning, !engine.isRunning {
            try? engine.start()
        }
        return format
    }

    /// Force rebuild of capture after route changes.
    private func reconnectMic() {
        // While recording, keep the hardware monitor path up if the rate is unchanged.
        if isRecording {
            prepareInputCapture()
            let format = engine.inputNode.inputFormat(forBus: 0)
            if format.sampleRate > 0,
               abs(micPathSampleRate - format.sampleRate) < 1,
               micPathSampleRate > 0 {
                if !inputTapInstalled {
                    installInputTapIfNeeded()
                }
                applyDesiredMonitor()
                return
            }
        }

        if inputTapInstalled {
            micSplitter.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        micPathSampleRate = 0
        engine.disconnectNodeOutput(engine.inputNode)
        // Do not call configureSession here — that can re-fire route changes mid-record.
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        prepareInputCapture()
        let needPath = isRecording || recordingFile != nil || wantsInputMetering || desiredMonitorEnabled
        if needPath {
            _ = connectMicPathIfNeeded()
        }
        if isRecording || recordingFile != nil || wantsInputMetering {
            installInputTapIfNeeded()
        }
    }

    func configureSession(forMonitoring: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        let activeCapture = forMonitoring || desiredMonitorEnabled || isRecording || wantsInputMetering
        let route = session.currentRoute
        let bluetooth = Self.routeIsBluetooth(route)
        // Wired: measurement (low latency, no AEC). Bluetooth: voiceChat for HFP headset mic.
        let mode: AVAudioSession.Mode
        if activeCapture {
            mode = bluetooth ? .voiceChat : .measurement
        } else {
            mode = .default
        }
        let buffer = activeCapture ? 0.005 : 0.01
        let options: AVAudioSession.CategoryOptions = [
            .defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers
        ]

        let alreadyConfigured =
            configuredSessionMode == mode
            && configuredForCapture == activeCapture
            && abs(configuredIOBufferDuration - buffer) < 0.0001
            && session.category == .playAndRecord
            && session.mode == mode

        if !alreadyConfigured {
            try session.setCategory(.playAndRecord, mode: mode, options: options)
            try session.setPreferredIOBufferDuration(buffer)
            try session.setActive(true)
            configuredSessionMode = mode
            configuredIOBufferDuration = buffer
            configuredForCapture = activeCapture
        }

        sampleRate = session.sampleRate
        refreshRouteState()
    }

    func startEngineIfNeeded() throws {
        try configureSession(forMonitoring: desiredMonitorEnabled || wantsInputMetering || isRecording)
        prepareInputCapture()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        reconnectMetronomeWithHardwareFormat()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        ensureClickBuffer()
    }

    /// Call immediately before any `AVAudioPlayerNode.play()`.
    @discardableResult
    private func ensureEngineRunning() -> Bool {
        if engine.isRunning { return true }
        do {
            try configureSession(forMonitoring: desiredMonitorEnabled || wantsInputMetering || isRecording)
            prepareInputCapture()
            engine.prepare()
            try engine.start()
            return engine.isRunning
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var metronomeConnectedRate: Double = 0

    private func reconnectMetronomeWithHardwareFormat() {
        let hwRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let rate = hwRate > 0 ? hwRate : self.sampleRate
        guard rate > 0 else { return }
        // Avoid tearing down the graph on every start — that stops the engine.
        if abs(metronomeConnectedRate - rate) < 1, metronomeConnectedRate > 0 {
            return
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let wasRunning = engine.isRunning
        engine.disconnectNodeOutput(metronomePlayer)
        engine.connect(metronomePlayer, to: metronomeMixer, format: format)
        engine.connect(metronomeMixer, to: engine.mainMixerNode, format: format)
        metronomeConnectedRate = rate
        if wasRunning, !engine.isRunning {
            try? engine.start()
        }
    }

    func setMasterVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = max(0, min(1, volume))
    }

    func setInstrumentalVolume(_ volume: Float) {
        instrumentalMixer.outputVolume = max(0, min(1, volume))
    }

    func setMetronomeVolume(_ enabled: Bool) {
        metronomeEnabled = enabled
        metronomeMixer.outputVolume = enabled ? 0.55 : 0
    }

    /// Live mic → headphones/BT via hardware passthrough (input → micSplitter → vocalMonitorMixer).
    func setInputMonitor(enabled: Bool, volume: Float) {
        desiredMonitorEnabled = enabled
        desiredMonitorVolume = max(0, min(1, volume))
        refreshRouteState()
        applyDesiredMonitor()
    }

    /// Keep a mic tap for level metering (e.g. while Input Monitor is armed).
    func setInputMeteringEnabled(_ enabled: Bool) {
        wantsInputMetering = enabled
        if enabled {
            try? startEngineIfNeeded()
            _ = connectMicPathIfNeeded()
        }
        syncInputTap()
        if !enabled && !isRecording {
            inputLevel = 0
        }
    }

    private func applyDesiredMonitor() {
        let safe = isHeadphoneOrBluetoothOutput
        monitorBlockedByRoute = desiredMonitorEnabled && !safe
        // While recording on headphones/BT, always monitor (even if I is off).
        let recordingMonitor = isRecording && safe
        let effective = (desiredMonitorEnabled && safe) || recordingMonitor
        if effective {
            do {
                try startEngineIfNeeded()
            } catch {
                errorMessage = error.localizedDescription
                vocalMonitorMixer.outputVolume = 0
                return
            }
            _ = connectMicPathIfNeeded()
            syncInputTap()
            let volume = recordingMonitor
                ? max(desiredMonitorVolume, 0.85)
                : desiredMonitorVolume
            vocalMonitorMixer.outputVolume = max(0.05, volume)
            _ = ensureEngineRunning()
        } else {
            vocalMonitorMixer.outputVolume = 0
        }
    }

    private func refreshRouteState() {
        isHeadphoneOrBluetoothOutput = Self.routeIsHeadphoneOrBluetooth(
            AVAudioSession.sharedInstance().currentRoute
        )
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            break
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) || desiredMonitorEnabled || wantsInputMetering || isPlaying || isRecording {
                _ = ensureEngineRunning()
                applyDesiredMonitor()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange() {
        refreshRouteState()
        let now = CFAbsoluteTimeGetCurrent()
        // Debounce route storms during record (often caused by our own session applies).
        if isRecording, now - lastRouteReconnectTime < 0.35 {
            applyDesiredMonitor()
            onRouteChange?()
            return
        }
        if engine.isRunning || desiredMonitorEnabled || isRecording || wantsInputMetering {
            lastRouteReconnectTime = now
            reconnectMic()
            if !engine.isRunning {
                _ = ensureEngineRunning()
            }
        }
        applyDesiredMonitor()
        onRouteChange?()
    }

    static func routeIsHeadphoneOrBluetooth(_ route: AVAudioSessionRouteDescription) -> Bool {
        let safe: Set<AVAudioSession.Port> = [
            .headphones,
            .headsetMic,
            .bluetoothA2DP,
            .bluetoothHFP,
            .bluetoothLE,
            .usbAudio
        ]
        return route.outputs.contains { safe.contains($0.portType) }
    }

    static func routeIsBluetooth(_ route: AVAudioSessionRouteDescription) -> Bool {
        let bt: Set<AVAudioSession.Port> = [
            .bluetoothA2DP,
            .bluetoothHFP,
            .bluetoothLE
        ]
        return route.outputs.contains { bt.contains($0.portType) }
            || route.inputs.contains { bt.contains($0.portType) }
    }

    func loadInstrumental(url: URL) throws {
        // Keep+next / region nav call applyAudioFromProject while transport is running.
        // Reloading the same file must not stop the player or the bed goes silent until the next loop.
        if let loaded = instrumentalLoadedURL,
           loaded.standardizedFileURL.path == url.standardizedFileURL.path,
           instrumentalFile != nil {
            return
        }
        let transportActive = isPlaying || isRecording
        instrumentalPlayer.stop()
        instrumentalFile = try AVAudioFile(forReading: url)
        instrumentalLoadedURL = url
        sampleRate = instrumentalFile?.processingFormat.sampleRate ?? sampleRate
        if transportActive, !isCountingIn {
            scheduleInstrumentalSegment(at: playheadSeconds)
            if ensureEngineRunning() {
                instrumentalPlayer.play()
            }
        }
    }

    /// Stop playback and drop the loaded instrumental so a deleted/replaced file cannot keep playing.
    func clearInstrumental() {
        instrumentalPlayer.stop()
        instrumentalFile = nil
        instrumentalLoadedURL = nil
        clearInstrumentalClipMapping()
        instrumentalMixer.outputVolume = 0
    }

    func setClipSchedule(_ clips: [ScheduledClip]) {
        let next = clips.filter { $0.gain > 0.0001 }
        // Skip no-op rebuilds (e.g. repeated "exclude record track" refreshes).
        if next == scheduledClips {
            return
        }
        scheduledClips = next
        // Drop cached readers so re-recorded files reopen fresh.
        clipFileCache.removeAll()
        let transportActive = isPlaying || isRecording
        if transportActive {
            stopClipPlayers()
            if !isCountingIn {
                let count = scheduleClips(at: playheadSeconds)
                startClipPlayers(count: count)
            }
        }
    }

    /// Map timeline time → file window for the instrumental clip.
    func setInstrumentalClipMapping(
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        timelineStartSeconds: Double
    ) {
        instrumentalSourceStartSeconds = max(0, sourceStartSeconds)
        instrumentalSourceEndSeconds = max(instrumentalSourceStartSeconds + 0.05, sourceEndSeconds)
        instrumentalTimelineStartSeconds = max(0, timelineStartSeconds)
        instrumentalClipMappingEnabled = true
    }

    func clearInstrumentalClipMapping() {
        instrumentalClipMappingEnabled = false
        instrumentalSourceStartSeconds = 0
        instrumentalSourceEndSeconds = 0
        instrumentalTimelineStartSeconds = 0
    }

    func updateTransportContext(
        bpm: Double,
        timeSignature: TimeSignature,
        loopEnabled: Bool,
        metronomeEnabled: Bool
    ) {
        self.bpm = bpm
        self.timeSignature = timeSignature
        self.loopEnabled = loopEnabled
        setMetronomeVolume(metronomeEnabled)
    }

    func setActiveRegion(_ region: RecordingRegion, resetPlayhead: Bool = true) {
        regionStartSeconds = region.startSeconds(bpm: bpm, timeSignature: timeSignature)
        regionDurationSeconds = region.durationSeconds(bpm: bpm, timeSignature: timeSignature)
        if resetPlayhead {
            playheadSeconds = regionStartSeconds
        }
    }

    /// End of playable arrangement when loop is off (instrumental + clips).
    func setArrangementEndSeconds(_ seconds: Double) {
        arrangementEndSeconds = max(0, seconds)
    }

    /// Window end for scheduling / stop.
    /// Loop wraps at region end only when playing into/through the loop; playhead otherwise uses arrangement end.
    private var playbackWindowEnd: Double {
        let regionEnd = regionStartSeconds + regionDurationSeconds
        if isRecording {
            return regionEnd
        }
        if loopEnabled, playheadSeconds < regionEnd - 0.001 {
            return regionEnd
        }
        return max(regionEnd, arrangementEndSeconds, playheadSeconds + 0.05)
    }

    /// Seek the playhead. When transport is running, reschedules audio from the new position.
    /// - Parameter clampToLoop: When true and loop is enabled, keep scrub inside the active region.
    func seekPlayhead(to seconds: Double, clampToLoop: Bool = false) {
        var target = max(0, seconds)
        if clampToLoop, loopEnabled, regionDurationSeconds > 0 {
            let regionEnd = regionStartSeconds + regionDurationSeconds
            target = min(max(target, regionStartSeconds), max(regionStartSeconds, regionEnd - 0.001))
        }
        playheadSeconds = target

        let transportActive = isPlaying || isRecording
        guard transportActive, !isCountingIn else { return }

        instrumentalPlayer.stop()
        stopClipPlayers()
        guard ensureEngineRunning() else { return }
        scheduleInstrumentalSegment(at: playheadSeconds)
        let count = scheduleClips(at: playheadSeconds)
        instrumentalPlayer.play()
        startClipPlayers(count: count)
        if metronomeEnabled, !metronomePlayer.isPlaying {
            metronomePlayer.play()
        }
        lastMetronomeBeat = -1
        loopBoundaryArmed = true
        playbackStartedOffset = playheadSeconds
        playbackStartedHostTime = mach_absolute_time()
        // Start mic writes only once the musical clock is running (avoids pre-roll silence).
        armRecordingWritesAlignedToClock()
        if isRecording {
            applyDesiredMonitor()
        }
        if displayLink == nil {
            startDisplayLink()
        }
    }

    /// Reschedule from current playhead without touching AVAudioSession / mic graph.
    func restartPlaybackFromPlayhead() {
        seekPlayhead(to: playheadSeconds)
    }

    /// Scrub: free playhead always when stopped or playing; clamp only while recording into the loop.
    func scrub(to seconds: Double) {
        let clamp = isRecording && loopEnabled
        seekPlayhead(to: seconds, clampToLoop: clamp)
    }

    func setLoopBoundaryHandler(_ handler: (() -> Void)?) {
        onLoopBoundary = handler
    }

    // MARK: - Playback

    func play(fromRegionStart: Bool = true) throws {
        try startEngineIfNeeded()
        stopPlayers(keepEngine: true)
        guard ensureEngineRunning() else {
            throw NSError(
                domain: "LoopFlow",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Audio engine failed to start"]
            )
        }

        if fromRegionStart {
            playheadSeconds = regionStartSeconds
        }
        // Playhead and loop selection stay independent: do not yank playhead into the region on Play.

        scheduleInstrumentalSegment(at: playheadSeconds)
        let scheduledClipCount = scheduleClips(at: playheadSeconds)
        scheduleMetronomeIfNeeded()

        guard ensureEngineRunning() else {
            throw NSError(
                domain: "LoopFlow",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Audio engine failed to start"]
            )
        }

        instrumentalPlayer.play()
        startClipPlayers(count: scheduledClipCount)
        if metronomeEnabled {
            metronomePlayer.play()
        }

        isPlaying = true
        isCountingIn = false
        lastMetronomeBeat = -1
        loopBoundaryArmed = true
        playbackStartedOffset = playheadSeconds
        playbackStartedHostTime = mach_absolute_time()
        // Start mic writes only once the musical clock is running (avoids pre-roll silence).
        armRecordingWritesAlignedToClock()
        // Re-assert monitor after startEngineIfNeeded/session churn.
        if isRecording {
            applyDesiredMonitor()
        }
        startDisplayLink()
    }

    func stop() {
        stopRecordingTap()
        stopPlayers(keepEngine: true)
        isPlaying = false
        isRecording = false
        isCountingIn = false
        loopBoundaryArmed = false
        displayLink?.invalidate()
        displayLink = nil
        playbackStartedHostTime = nil
        if !wantsInputMetering {
            inputLevel = 0
        }
    }

    /// Stop transport and leave the playhead where it is (VM seeks after).
    func stopTransportPreservingPlayhead() {
        let head = playheadSeconds
        stop()
        playheadSeconds = head
    }

    private func stopPlayers(keepEngine: Bool) {
        instrumentalPlayer.stop()
        metronomePlayer.stop()
        stopClipPlayers()
        if !keepEngine, engine.isRunning {
            engine.stop()
        }
    }

    private func stopClipPlayers() {
        for player in clipPlayers {
            player.stop()
            player.volume = 1
        }
    }

    private func startClipPlayers(count: Int) {
        let n = min(count, clipPlayers.count)
        guard n > 0, ensureEngineRunning() else { return }
        for i in 0..<n {
            let player = clipPlayers[i]
            if !player.isPlaying {
                player.play()
            }
        }
    }

    private func audioFile(for url: URL) -> AVAudioFile? {
        if let cached = clipFileCache[url] { return cached }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        clipFileCache[url] = file
        return file
    }

    @discardableResult
    private func scheduleClips(at timelineSeconds: Double) -> Int {
        let windowEnd = playbackWindowEnd
        var playerIndex = 0
        for clip in scheduledClips {
            guard playerIndex < clipPlayers.count else { break }
            guard let file = audioFile(for: clip.url) else { continue }
            let rate = file.processingFormat.sampleRate
            let fileDuration = Double(file.length) / rate
            guard fileDuration > 0.001, file.length > 0 else { continue }
            let srcStart = max(0, clip.sourceStartSeconds)
            let srcEnd = min(max(srcStart + 0.05, clip.sourceEndSeconds), fileDuration)
            let clipTimelineStart = clip.timelineStartSeconds
            let clipTimelineEnd = clipTimelineStart + max(0, srcEnd - srcStart)

            let audibleStart = max(timelineSeconds, clipTimelineStart)
            let audibleEnd = min(windowEnd, clipTimelineEnd)
            let audibleDur = audibleEnd - audibleStart
            guard audibleDur > 0.001 else { continue }

            let fileStart = srcStart + (audibleStart - clipTimelineStart)
            let maxFileSeconds = max(0, srcEnd - fileStart)
            let playSeconds = min(audibleDur, maxFileSeconds)
            guard playSeconds > 0.001 else { continue }

            let startFrame = AVAudioFramePosition(max(0, fileStart) * rate)
            guard startFrame < file.length else { continue }
            let frameCount = AVAudioFrameCount(min(playSeconds * rate, Double(file.length - startFrame)))
            guard frameCount > 0 else { continue }

            let delay = audibleStart - timelineSeconds
            let player = clipPlayers[playerIndex]
            let when: AVAudioTime?
            if delay > 0.001 {
                let playerRate = player.outputFormat(forBus: 0).sampleRate
                let scheduleRate = playerRate > 0 ? playerRate : rate
                when = AVAudioTime(
                    sampleTime: AVAudioFramePosition(delay * scheduleRate),
                    atRate: scheduleRate
                )
            } else {
                when = nil
            }

            player.volume = max(0, min(1, clip.gain))
            player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: frameCount,
                at: when,
                completionHandler: nil
            )
            playerIndex += 1
        }
        return playerIndex
    }

    private func scheduleInstrumentalSegment(at timelineSeconds: Double) {
        guard let file = instrumentalFile else { return }
        let rate = file.processingFormat.sampleRate
        let fileDuration = Double(file.length) / rate
        let windowEnd = playbackWindowEnd
        let remaining = windowEnd - timelineSeconds
        guard remaining > 0.001 else { return }

        let srcStart: Double
        let srcEnd: Double
        let clipTimelineStart: Double
        if instrumentalClipMappingEnabled {
            srcStart = instrumentalSourceStartSeconds
            srcEnd = min(instrumentalSourceEndSeconds, fileDuration)
            clipTimelineStart = instrumentalTimelineStartSeconds
        } else {
            srcStart = 0
            srcEnd = fileDuration
            clipTimelineStart = 0
        }
        let clipTimelineEnd = clipTimelineStart + max(0, srcEnd - srcStart)

        // Overlap of the remaining playback window with the mapped clip on the timeline.
        let audibleStart = max(timelineSeconds, clipTimelineStart)
        let audibleEnd = min(windowEnd, clipTimelineEnd)
        let audibleDur = audibleEnd - audibleStart
        guard audibleDur > 0.001 else { return }

        let fileStart = srcStart + (audibleStart - clipTimelineStart)
        let maxFileSeconds = max(0, srcEnd - fileStart)
        let playSeconds = min(audibleDur, maxFileSeconds)
        guard playSeconds > 0.001 else { return }

        let startFrame = AVAudioFramePosition(max(0, fileStart) * rate)
        guard startFrame < file.length else { return }
        let frameCount = AVAudioFrameCount(min(playSeconds * rate, Double(file.length - startFrame)))
        guard frameCount > 0 else { return }

        // Loop timing is driven by host-time in displayTick — no completion handler.
        let delay = audibleStart - timelineSeconds
        let when: AVAudioTime?
        if delay > 0.001 {
            let playerRate = instrumentalPlayer.outputFormat(forBus: 0).sampleRate
            let scheduleRate = playerRate > 0 ? playerRate : rate
            when = AVAudioTime(
                sampleTime: AVAudioFramePosition(delay * scheduleRate),
                atRate: scheduleRate
            )
        } else {
            when = nil
        }
        instrumentalPlayer.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: when,
            completionHandler: nil
        )
    }

    private func handleLoopBoundary() {
        guard isPlaying || isRecording else { return }
        guard loopBoundaryArmed else { return }
        loopBoundaryArmed = false

        if loopEnabled {
            playheadSeconds = regionStartSeconds
            onLoopBoundary?()
            instrumentalPlayer.stop()
            stopClipPlayers()
            guard ensureEngineRunning() else { return }
            scheduleInstrumentalSegment(at: regionStartSeconds)
            let count = scheduleClips(at: regionStartSeconds)
            if !instrumentalPlayer.isPlaying {
                instrumentalPlayer.play()
            }
            startClipPlayers(count: count)
            lastMetronomeBeat = -1
            loopBoundaryArmed = true
            playbackStartedOffset = regionStartSeconds
            playbackStartedHostTime = mach_absolute_time()
            armRecordingWritesAlignedToClock()
        } else {
            stop()
        }
    }

    // MARK: - Metronome / Count-in

    private var clickBuffer: AVAudioPCMBuffer?

    private func ensureClickBuffer() {
        let playerFormat = metronomePlayer.outputFormat(forBus: 0)
        let hardwareRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let rate = playerFormat.sampleRate > 0
            ? playerFormat.sampleRate
            : (hardwareRate > 0 ? hardwareRate : 44_100)
        let channels: AVAudioChannelCount = playerFormat.channelCount > 0
            ? playerFormat.channelCount
            : 2

        if let existing = clickBuffer,
           existing.format.channelCount == channels,
           abs(existing.format.sampleRate - rate) < 1 {
            return
        }

        clickBuffer = AudioNodeFactory.makeClickBuffer(sampleRate: rate, channels: channels)
    }

    private func scheduleMetronomeIfNeeded() {
        ensureClickBuffer()
        // Metronome clicks are driven from display link for simplicity in V1.
    }

    func startCountIn(beats: Int, completion: @escaping () -> Void) throws {
        try startEngineIfNeeded()
        countInBeatsRemaining = beats
        lastMetronomeBeat = -1
        isCountingIn = true
        isPlaying = true
        playheadSeconds = regionStartSeconds
        onCountInFinished = completion
        playbackStartedOffset = 0
        playbackStartedHostTime = mach_absolute_time()
        setMetronomeVolume(true)
        startDisplayLink()
        ensureClickBuffer()
    }

    // MARK: - Recording tap + metering

    func beginRecording(to url: URL) throws {
        try startEngineIfNeeded()
        guard let hwFormat = connectMicPathIfNeeded(), hwFormat.sampleRate > 0 else {
            throw NSError(domain: "LoopFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable"])
        }

        // Hardware buffers are often non-interleaved; AVAudioFile requires interleaved PCM.
        guard let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: hwFormat.channelCount,
            interleaved: true
        ) else {
            throw NSError(domain: "LoopFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create recording format"])
        }

        if FileManager.default.fileExists(atPath: url.path) {
            // Release any cached readers before overwriting a deleted take's path.
            clipFileCache.removeValue(forKey: url)
            try FileManager.default.removeItem(at: url)
        }
        recordingFile = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        recordingFileForTap = recordingFile
        recordingWriteFormat = fileFormat
        if hwFormat != fileFormat {
            recordingConverter = AVAudioConverter(from: hwFormat, to: fileFormat)
        } else {
            recordingConverter = nil
        }
        recordingWriteEnabled = false
        isRecording = true
        syncInputTap()
        // Hear yourself while recording when on headphones/BT (even if I is off).
        applyDesiredMonitor()
    }

    func rotateRecordingFile(to url: URL) throws {
        // Stop tap writes so the previous WAV can finalize its header.
        recordingWriteEnabled = false
        recordingFileForTap = nil
        recordingFile = nil

        let hwFormat = engine.inputNode.inputFormat(forBus: 0)
        guard let fileFormat = recordingWriteFormat ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate > 0 ? hwFormat.sampleRate : 44_100,
            channels: max(1, hwFormat.channelCount),
            interleaved: true
        ) else {
            throw NSError(domain: "LoopFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create recording format"])
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        recordingFile = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        recordingFileForTap = recordingFile
        recordingWriteFormat = fileFormat
        if hwFormat.sampleRate > 0, hwFormat != fileFormat {
            recordingConverter = AVAudioConverter(from: hwFormat, to: fileFormat)
        }
        // Leave writes off until the musical clock restarts (play / seek / loop wrap).
        recordingWriteEnabled = false
    }

    /// Enable mic file writes aligned to the current host clock (and refresh latency stamp).
    func armRecordingWritesAlignedToClock() {
        guard isRecording, recordingFile != nil else { return }
        activeRecordingLatencySeconds = roundTripLatencySeconds
        recordingWriteEnabled = true
    }

    func closeCurrentRecordingFile() {
        recordingWriteEnabled = false
        recordingFileForTap = nil
        recordingFile = nil
    }

    /// Read take duration after close/rotate; retries briefly while the WAV header settles.
    /// While recording, never sleep on the main actor (causes monitor underruns/static).
    func measureTakeDuration(url: URL, retries: Int = 6) -> Double {
        let attempts = isRecording ? 1 : max(1, retries)
        for attempt in 0..<attempts {
            if let duration = try? AVAudioFileBridge.duration(url: url), duration > 0.001 {
                return duration
            }
            if attempt + 1 < attempts {
                usleep(20_000)
            }
        }
        return (try? AVAudioFileBridge.duration(url: url)) ?? 0
    }

    func stopRecordingTap() {
        recordingWriteEnabled = false
        recordingFile = nil
        recordingFileForTap = nil
        recordingConverter = nil
        recordingWriteFormat = nil
        isRecording = false
        syncInputTap()
        applyDesiredMonitor()
        if !wantsInputMetering {
            inputLevel = 0
        }
    }

    private func syncInputTap() {
        let needTap = isRecording || recordingFile != nil || wantsInputMetering
        if needTap {
            installInputTapIfNeeded()
        } else if inputTapInstalled {
            micSplitter.removeTap(onBus: 0)
            inputTapInstalled = false
        }
    }

    private func installInputTapIfNeeded() {
        guard !inputTapInstalled else { return }
        guard let format = connectMicPathIfNeeded() else {
            errorMessage = "Mic unavailable (format 0) — check permissions / route"
            return
        }

        // Tap splitter (not inputNode) so hardware passthrough stays audible.
        micSplitter.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let peak = Self.bufferPeakLevel(buffer)
            if self.recordingWriteEnabled {
                Self.writeRecordingBuffer(
                    buffer,
                    file: self.recordingFileForTap,
                    converter: self.recordingConverter,
                    writeFormat: self.recordingWriteFormat
                ) { message in
                    Task { @MainActor in
                        self.errorMessage = message
                    }
                }
            }
            Task { @MainActor in
                self.smoothInputLevel(peak)
            }
        }
        inputTapInstalled = true
        _ = ensureEngineRunning()
    }

    private nonisolated static func writeRecordingBuffer(
        _ buffer: AVAudioPCMBuffer,
        file: AVAudioFile?,
        converter: AVAudioConverter?,
        writeFormat: AVAudioFormat?,
        onError: (String) -> Void
    ) {
        guard let file else { return }
        do {
            if let converter, let writeFormat {
                guard let outBuffer = AVAudioPCMBuffer(
                    pcmFormat: writeFormat,
                    frameCapacity: buffer.frameLength
                ) else { return }
                var error: NSError?
                var provided = false
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if provided {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    provided = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
                if let error {
                    onError(error.localizedDescription)
                    return
                }
                try file.write(from: outBuffer)
            } else {
                try file.write(from: buffer)
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    private static func bufferPeakLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        if let channels = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            for ch in 0..<max(1, channelCount) {
                let data = channels[ch]
                for i in 0..<frames {
                    peak = max(peak, abs(data[i]))
                }
            }
        } else if let channels = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            for ch in 0..<max(1, channelCount) {
                let data = channels[ch]
                for i in 0..<frames {
                    peak = max(peak, abs(Float(data[i]) / Float(Int16.max)))
                }
            }
        }
        // Boost quiet mics for UI (still clamps to 1).
        return min(1, peak * 2.5)
    }

    private func smoothInputLevel(_ peak: Float) {
        let attack: Float = 0.55
        let release: Float = 0.12
        if peak > inputLevel {
            inputLevel = inputLevel + (peak - inputLevel) * attack
        } else {
            inputLevel = inputLevel + (peak - inputLevel) * release
        }
        if inputLevel < 0.001 { inputLevel = 0 }
    }

    // MARK: - Display link playhead

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func displayTick() {
        guard let start = playbackStartedHostTime else { return }
        let elapsed = hostTimeToSeconds(mach_absolute_time() - start)

        if isCountingIn {
            let beatDuration = TimelineManager.secondsPerBeat(bpm: bpm)
            let beatIndex = Int(elapsed / beatDuration)
            if beatIndex != lastMetronomeBeat, beatIndex < countInBeatsRemaining {
                lastMetronomeBeat = beatIndex
                fireClick(accent: beatIndex % timeSignature.beatsPerBar == 0)
            }
            if elapsed >= Double(countInBeatsRemaining) * beatDuration {
                isCountingIn = false
                lastMetronomeBeat = -1
                let finish = onCountInFinished
                onCountInFinished = nil
                playbackStartedHostTime = nil
                finish?()
            }
            return
        }

        if isPlaying || isRecording {
            let position = playbackStartedOffset + elapsed
            let regionEnd = regionStartSeconds + regionDurationSeconds

            // Loop wrap only when playing through the loop end — not when starting past it.
            let shouldWrapLoop = (loopEnabled || isRecording)
                && position >= regionEnd
                && playbackStartedOffset < regionEnd - 0.001

            if shouldWrapLoop {
                handleLoopBoundary()
                // After boundary, playhead/host clock are reset; show region start this frame.
                playheadSeconds = regionStartSeconds
            } else {
                playheadSeconds = position
                let stopAt = isRecording
                    ? regionEnd
                    : max(regionEnd, arrangementEndSeconds, playbackStartedOffset + 0.05)
                if !shouldWrapLoop, position >= stopAt {
                    stop()
                    return
                }
            }

            if metronomeEnabled, isPlaying || isRecording {
                let beatDuration = TimelineManager.secondsPerBeat(bpm: bpm)
                let globalBeat = Int(playheadSeconds / beatDuration)
                if globalBeat != lastMetronomeBeat {
                    lastMetronomeBeat = globalBeat
                    fireClick(accent: globalBeat % timeSignature.beatsPerBar == 0)
                }
            }
        }
    }

    private func fireClick(accent: Bool) {
        ensureClickBuffer()
        guard let buffer = clickBuffer else { return }
        let playerChannels = metronomePlayer.outputFormat(forBus: 0).channelCount
        guard playerChannels == 0 || buffer.format.channelCount == playerChannels else {
            clickBuffer = nil
            ensureClickBuffer()
            guard let rebuilt = clickBuffer,
                  metronomePlayer.outputFormat(forBus: 0).channelCount == 0
                    || rebuilt.format.channelCount == metronomePlayer.outputFormat(forBus: 0).channelCount
            else { return }
            scheduleClick(rebuilt, accent: accent)
            return
        }
        scheduleClick(buffer, accent: accent)
    }

    private func scheduleClick(_ buffer: AVAudioPCMBuffer, accent: Bool) {
        if accent { /* accent uses same buffer; volume via mixer */ }
        guard ensureEngineRunning() else { return }
        metronomePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !metronomePlayer.isPlaying {
            metronomePlayer.play()
        }
    }

    private func hostTimeToSeconds(_ delta: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = Double(delta) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000
    }
}

/// Avoids retain cycle with CADisplayLink target.
private final class DisplayLinkProxy: NSObject {
    weak var owner: AudioEngineManager?
    init(owner: AudioEngineManager) { self.owner = owner }

    @objc func tick() {
        // CADisplayLink is on the main run loop; hop explicitly for Swift concurrency.
        let engine = owner
        Task { @MainActor in
            engine?.displayTick()
        }
    }
}
