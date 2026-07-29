import Foundation
@preconcurrency import AVFoundation
import UIKit
import QuartzCore
import os

/// A non-instrumental clip ready for live playback scheduling.
struct ScheduledClip: Equatable {
    var url: URL
    var sourceStartSeconds: Double
    var sourceEndSeconds: Double
    var timelineStartSeconds: Double
    var gain: Float
    /// Track pan −1…1 (left…right).
    var pan: Float

    /// Identity for schedule rebuilds — ignores live mix (gain/pan).
    func matchesContent(_ other: ScheduledClip) -> Bool {
        url == other.url
            && abs(sourceStartSeconds - other.sourceStartSeconds) < 1e-6
            && abs(sourceEndSeconds - other.sourceEndSeconds) < 1e-6
            && abs(timelineStartSeconds - other.timelineStartSeconds) < 1e-6
    }
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
    private var desiredMonitorPan: Float = 0
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
    /// Per-player readers so split halves sharing a URL don't share mutable `AVAudioFile` state.
    private var clipFileCache: [Int: (url: URL, file: AVAudioFile)] = [:]
    /// Exact clip each player is serving (soft-mute by identity, not shared path).
    private var clipPlayerScheduledClips: [ScheduledClip?] = Array(repeating: nil, count: 8)
    /// Split / bound changes while mic is live — rebuild players once the mic path goes idle.
    private var pendingClipHardRefresh = false
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
    /// Region jumped while transport is live but players not yet restarted — the old player
    /// sample clock is stale, so displayTick must not derive a position until re-anchor.
    private var transportReanchorPending = false
    /// Ruler scrub in progress — playhead moves without per-frame reschedule.
    private var isPlayheadScrubbing = false
    /// Resume transport with one seek when scrub ends.
    private var resumePlaybackAfterPlayheadScrub = false
    private var playheadScrubClampToLoop = false

    private var recordingFile: AVAudioFile?
    /// Nonisolated handle for the audio-thread tap write (mirrors `recordingFile`).
    private nonisolated(unsafe) var recordingFileForTap: AVAudioFile?
    private nonisolated(unsafe) var recordingConverter: AVAudioConverter?
    private nonisolated(unsafe) var recordingWriteFormat: AVAudioFormat?
    /// Gate so close/rotate can finalize the WAV before the tap writes again.
    private nonisolated(unsafe) var recordingWriteEnabled = false
    /// Host time when writes armed — the musical zero the first written buffer is trimmed to.
    private nonisolated(unsafe) var recordingArmHostTime: UInt64 = 0
    /// Diagnostic: seconds from arm → first written tap buffer (−1 = not captured yet).
    /// The first buffer is trimmed to the arm instant, so this no longer shifts takes.
    private nonisolated(unsafe) var recordingWriteSkewSeconds: TimeInterval = -1
    /// Latest mic peak from the audio-thread tap (published on the display link).
    private nonisolated(unsafe) var tapPeakLevel: Float = 0
    /// Deferred tap write error (published on the display link — never hop MainActor from the tap).
    private nonisolated(unsafe) var pendingTapError: String?
    private var inputTapInstalled = false
    /// Sample rate of the current `inputNode → micSplitter` connection (0 = not connected).
    private var micPathSampleRate: Double = 0
    /// Last applied session config (skip no-op reconfigs that trigger route rebuilds).
    private var configuredSessionMode: AVAudioSession.Mode?
    private var configuredIOBufferDuration: TimeInterval = -1
    private var configuredForCapture = false
    /// Keep `.measurement` / capture IO across play→arm so Keep→Record doesn’t thrash the mic graph.
    private var holdCaptureSession = false
    /// Hardware format used when the mic tap was installed (rotate must match this).
    private var micTapFormat: AVAudioFormat?
    private var lastRouteReconnectTime: CFAbsoluteTime = 0
    private var onLoopBoundary: (() -> Void)?
    private var onCountInFinished: (() -> Void)?
    /// One-shot: fires when mic writes arm at region start after a lead-in pre-roll.
    private var onRecordingPunchIn: (() -> Void)?

    private var bpm: Double = 120
    private var timeSignature = TimeSignature.fourFour
    private var metronomeEnabled = true
    private var sampleRate: Double = 44_100

    private var countInBeatsRemaining = 0
    private var lastMetronomeBeat: Int = -1
    /// When true, the next host-time crossing of region end may fire a loop boundary.
    private var loopBoundaryArmed = false
    /// User scrubbed while playing — don't wrap/stop at the loop end until the next play/stop.
    private var suppressLoopWrapUntilStop = false

    /// Mic meter/record tap size (installTap only — not part of Keep trim after write-arm align).
    static let recordingTapBufferFrames: AVAudioFrameCount = 1024

    /// Transport/record timing diagnostics (Console.app / Xcode: subsystem LoopFlow).
    static let transportLog = Logger(subsystem: "LoopFlow", category: "Transport")

    /// Round-trip I/O latency for aligning recorded takes to what was heard.
    /// Prefer engine presentation latencies (session figures often under-report through AVAudioEngine).
    /// Include two IO buffers (play + capture) and the mic tap quantum — presentation latencies
    /// alone under-estimate Keep trim on device (~tens of ms late without this).
    var roundTripLatencySeconds: TimeInterval {
        let session = AVAudioSession.sharedInstance()
        let input = max(session.inputLatency, engine.inputNode.presentationLatency)
        let output = max(session.outputLatency, engine.outputNode.presentationLatency)
        let rate = sampleRate > 0 ? sampleRate : max(session.sampleRate, 44_100)
        let tapSeconds = Double(Self.recordingTapBufferFrames) / rate
        return max(0, input + output + session.ioBufferDuration * 2 + tapSeconds)
    }

    /// User fine-tune from Settings (milliseconds → seconds). Positive = trim more (fix late takes).
    var recordingLatencyOffsetSeconds: TimeInterval {
        Double(UserDefaults.standard.integer(forKey: Self.recordingLatencyOffsetKey)) / 1000.0
    }

    static let recordingLatencyOffsetKey = "recordingLatencyOffsetMilliseconds"

    /// Latency frozen when mic writes armed for the current recording pass.
    private(set) var activeRecordingLatencySeconds: TimeInterval = 0
    /// Measured arm → first-write delay for the current pass (0 if not yet captured).
    var activeRecordingWriteSkewSeconds: TimeInterval {
        let skew = recordingWriteSkewSeconds
        return skew >= 0 ? skew : 0
    }

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
        let activeCapture = forMonitoring || desiredMonitorEnabled || isRecording
            || wantsInputMetering || holdCaptureSession
        let route = session.currentRoute
        let bluetooth = Self.routeIsBluetooth(route)
        // Wired: measurement (low latency, no AEC). Bluetooth: voiceChat for HFP headset mic.
        let mode: AVAudioSession.Mode
        if activeCapture {
            mode = bluetooth ? .voiceChat : .measurement
        } else {
            mode = .default
        }
        // Slightly larger capture buffer — 5ms underruns show up as monitor/WAV static.
        let buffer = activeCapture ? 0.01 : 0.01
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
            // Category/mode changes rebuild IO — cached mic graph is stale.
            micPathSampleRate = 0
            micTapFormat = nil
        }

        sampleRate = session.sampleRate
        refreshRouteState()
    }

    /// Arm capture IO before transport starts so `play()` cannot drop `.measurement`→`.default`.
    /// Call at the start of every record arm (before schedule refresh / play).
    func prepareForRecording() throws {
        holdCaptureSession = true
        try configureSession(forMonitoring: true)
        prepareInputCapture()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        reconnectMetronomeWithHardwareFormat()
        _ = connectMicPathIfNeeded()
        // Install tap early (writes still gated) so beginRecording can reuse the path.
        syncInputTap()
    }

    func releaseCaptureHold() {
        guard holdCaptureSession else { return }
        holdCaptureSession = false
        syncInputTap()
        // Drop back to playback session only when mic path is fully idle.
        if !desiredMonitorEnabled && !wantsInputMetering && !isRecording && recordingFile == nil {
            try? configureSession(forMonitoring: false)
        }
    }

    func startEngineIfNeeded() throws {
        try configureSession(
            forMonitoring: desiredMonitorEnabled || wantsInputMetering || isRecording || holdCaptureSession
        )
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
            try configureSession(
                forMonitoring: desiredMonitorEnabled || wantsInputMetering || isRecording || holdCaptureSession
            )
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

    func setInstrumentalPan(_ pan: Float) {
        instrumentalMixer.pan = max(-1, min(1, pan))
    }

    func setMetronomeVolume(_ enabled: Bool) {
        metronomeEnabled = enabled
        metronomeMixer.outputVolume = enabled ? 0.55 : 0
    }

    /// Live mic → headphones/BT via hardware passthrough (input → micSplitter → vocalMonitorMixer).
    func setInputMonitor(enabled: Bool, volume: Float, pan: Float = 0) {
        desiredMonitorEnabled = enabled
        desiredMonitorVolume = max(0, min(1, volume))
        desiredMonitorPan = max(-1, min(1, pan))
        refreshRouteState()
        applyDesiredMonitor()
        flushPendingClipHardRefreshIfNeeded()
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
        flushPendingClipHardRefreshIfNeeded()
    }

    private var isMicPathLive: Bool {
        isRecording || desiredMonitorEnabled || wantsInputMetering || recordingFile != nil
            || vocalMonitorMixer.outputVolume > 0.001
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
            // Prefer track Input Monitor volume; when I is off, a moderate floor (not 0.85).
            let volume = recordingMonitor
                ? (desiredMonitorVolume > 0.001 ? desiredMonitorVolume : 0.55)
                : desiredMonitorVolume
            vocalMonitorMixer.outputVolume = recordingMonitor ? max(0.05, volume) : volume
            vocalMonitorMixer.pan = desiredMonitorPan
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
                // Instrumental is the preferred transport clock; its sample time just reset.
                anchorPlaybackClock(at: playheadSeconds)
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

        // Same clips, only gain/pan changed — update running players without stop/reschedule.
        if Self.clipContentMatches(next, scheduledClips) {
            scheduledClips = next
            applyLiveClipMix(next)
            return
        }

        let previous = scheduledClips
        let removed = previous.filter { old in !next.contains(where: { $0.matchesContent(old) }) }
        // Record-track exclude is removals-only; split/trim adds or changes bounds.
        let isRemovalsOnly = next.allSatisfy { new in previous.contains(where: { $0.matchesContent(new) }) }

        scheduledClips = next

        // Soft-mute whenever the mic path is live — not only after isRecording flips.
        // Never rebuild clip players under a live monitor (static lands in the record tap too).
        if isMicPathLive {
            if !removed.isEmpty {
                silenceScheduledClips(removed)
            }
            if !isRemovalsOnly {
                pendingClipHardRefresh = true
            }
            return
        }

        performClipHardRefresh()
    }

    /// True when both schedules list the same clip content (order-independent), ignoring gain/pan.
    private static func clipContentMatches(_ a: [ScheduledClip], _ b: [ScheduledClip]) -> Bool {
        guard a.count == b.count else { return false }
        var remaining = b
        for clip in a {
            guard let idx = remaining.firstIndex(where: { $0.matchesContent(clip) }) else { return false }
            remaining.remove(at: idx)
        }
        return remaining.isEmpty
    }

    /// Push gain/pan onto already-scheduled players without tearing them down.
    private func applyLiveClipMix(_ next: [ScheduledClip]) {
        for i in clipPlayers.indices {
            guard let serving = clipPlayerScheduledClips[i] else { continue }
            guard let updated = next.first(where: { $0.matchesContent(serving) }) else { continue }
            clipPlayers[i].volume = max(0, min(1, updated.gain))
            clipPlayers[i].pan = max(-1, min(1, updated.pan))
            clipPlayerScheduledClips[i] = updated
        }
    }

    /// Mute/stop players serving removed clips without tearing down the rest of the graph.
    private func silenceScheduledClips(_ removed: [ScheduledClip]) {
        for i in clipPlayers.indices {
            guard let serving = clipPlayerScheduledClips[i],
                  removed.contains(where: { $0.matchesContent(serving) }) else { continue }
            clipPlayers[i].volume = 0
            clipPlayers[i].stop()
            clipPlayerScheduledClips[i] = nil
            clipFileCache.removeValue(forKey: i)
        }
    }

    private func performClipHardRefresh() {
        pendingClipHardRefresh = false
        // Drop cached readers so re-recorded / re-split files reopen fresh.
        clipFileCache.removeAll()
        let transportActive = isPlaying || isRecording
        if transportActive {
            stopClipPlayers()
            if !isCountingIn {
                let count = scheduleClips(at: playheadSeconds)
                startClipPlayers(count: count)
                // With no bed running, a clip player is the transport clock — its sample
                // time just reset, so re-anchor to keep the playhead where it is.
                if !instrumentalPlayer.isPlaying {
                    anchorPlaybackClock(at: playheadSeconds)
                }
            }
        }
    }

    private func flushPendingClipHardRefreshIfNeeded() {
        guard pendingClipHardRefresh, !isMicPathLive else { return }
        performClipHardRefresh()
    }

    /// Map timeline time → file window for the instrumental clip.
    func setInstrumentalClipMapping(
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        timelineStartSeconds: Double
    ) {
        let newSourceStart = max(0, sourceStartSeconds)
        let newSourceEnd = max(newSourceStart + 0.05, sourceEndSeconds)
        let newTimelineStart = max(0, timelineStartSeconds)
        // No-op remaps (metronome toggle / applyAudioFromProject) must not restart the bed
        // mid-transport — that resets the player sample clock and yanks the playhead.
        if instrumentalClipMappingEnabled,
           abs(instrumentalSourceStartSeconds - newSourceStart) < 1e-6,
           abs(instrumentalSourceEndSeconds - newSourceEnd) < 1e-6,
           abs(instrumentalTimelineStartSeconds - newTimelineStart) < 1e-6 {
            return
        }
        instrumentalSourceStartSeconds = newSourceStart
        instrumentalSourceEndSeconds = newSourceEnd
        instrumentalTimelineStartSeconds = newTimelineStart
        instrumentalClipMappingEnabled = true
        rescheduleInstrumentalIfTransportActive()
    }

    func clearInstrumentalClipMapping() {
        instrumentalClipMappingEnabled = false
        instrumentalSourceStartSeconds = 0
        instrumentalSourceEndSeconds = 0
        instrumentalTimelineStartSeconds = 0
    }

    /// Keep the bed in sync when mapping changes mid-transport (mirrors clip schedule refresh).
    private func rescheduleInstrumentalIfTransportActive() {
        let transportActive = isPlaying || isRecording
        guard transportActive, !isCountingIn else { return }
        instrumentalPlayer.stop()
        guard ensureEngineRunning() else { return }
        scheduleInstrumentalSegment(at: playheadSeconds)
        instrumentalPlayer.play()
        // The instrumental player is the preferred transport clock and its sample time just
        // reset to zero — re-anchor or the playhead snaps back to the old play origin.
        anchorPlaybackClock(at: playheadSeconds)
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
            // Freeze displayTick until jump/seek re-anchors — the still-running players carry
            // the old region's sample clock, which must not overwrite the new region playhead
            // between advanceRegion and continueRecording.
            if isPlaying || isRecording {
                playbackStartedOffset = regionStartSeconds
                playbackStartedHostTime = nil
                transportReanchorPending = true
            }
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
        if loopEnabled, !suppressLoopWrapUntilStop, playheadSeconds < regionEnd - 0.001 {
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
        metronomePlayer.stop()
        stopClipPlayers()
        guard ensureEngineRunning() else { return }
        scheduleInstrumentalSegment(at: playheadSeconds)
        let count = scheduleClips(at: playheadSeconds)
        scheduleMetronomeClicks(from: playheadSeconds)
        let startHost = startTransportPlayers(clipCount: count, at: playheadSeconds)
        loopBoundaryArmed = true
        // Start mic writes only once the musical clock is running (avoids pre-roll silence).
        armRecordingWritesAlignedToClock(atHostTime: startHost)
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

    /// Region navigation while playing (not armed): make the audio follow the region jump.
    /// `setActiveRegion(resetPlayhead: true)` freezes the display clock expecting a re-anchor;
    /// this is that re-anchor for the play-only path.
    func resyncPlaybackToRegionStartIfPlaying() {
        guard isPlaying, !isRecording, !isCountingIn else { return }
        seekPlayhead(to: regionStartSeconds, clampToLoop: false)
    }

    /// Keep+Next while armed: jump to the new region start and lock overdub cues to the record clock.
    func continueRecordingAtRegionStart() {
        jumpToRegionStartPreservingPlayback(armRecordingOnStart: true)
        applyDesiredMonitor()
    }

    /// Restart the musical clock at region start and reschedule instrumental + other-track clips
    /// so overdub cues share the same zero as mic write-arm. Ducks the monitor briefly (like `play()`)
    /// so clip rebuild under a live mic does not inject static into the take.
    func jumpToRegionStartPreservingPlayback(armRecordingOnStart: Bool = false) {
        let handoffStart = mach_absolute_time()
        playheadSeconds = regionStartSeconds
        let restoreMonitor = isRecording || desiredMonitorEnabled || wantsInputMetering
            || vocalMonitorMixer.outputVolume > 0.001
        if restoreMonitor {
            vocalMonitorMixer.outputVolume = 0
        }

        instrumentalPlayer.stop()
        metronomePlayer.stop()
        stopClipPlayers()
        guard ensureEngineRunning() else {
            if restoreMonitor { applyDesiredMonitor() }
            return
        }
        scheduleInstrumentalSegment(at: playheadSeconds)
        let clipCount = scheduleClips(at: playheadSeconds)
        scheduleMetronomeClicks(from: playheadSeconds)
        let startHost = startTransportPlayers(clipCount: clipCount, at: playheadSeconds)
        loopBoundaryArmed = true
        suppressLoopWrapUntilStop = false
        isPlaying = true
        if armRecordingOnStart {
            armRecordingWritesAlignedToClock(atHostTime: startHost)
        }
        if restoreMonitor || isRecording {
            applyDesiredMonitor()
        }
        if displayLink == nil {
            startDisplayLink()
        }
        let handoffMs = Self.hostTimeToSeconds(mach_absolute_time() &- handoffStart) * 1000
        Self.transportLog.info(
            "region jump: start=\(self.regionStartSeconds, format: .fixed(precision: 3))s clips=\(clipCount) arm=\(armRecordingOnStart) handoff=\(handoffMs, format: .fixed(precision: 1))ms"
        )
    }

    /// Scrub playhead freely (not clamped to the loop). While playing, disables loop wrap for this run.
    func scrub(to seconds: Double) {
        if isPlaying, !isRecording {
            suppressLoopWrapUntilStop = true
        }
        seekPlayhead(to: seconds, clampToLoop: false)
    }

    /// Start a ruler drag: freeze audio clock and stop players if playing (one resync on end).
    func beginPlayheadScrub() {
        guard !isPlayheadScrubbing else { return }
        isPlayheadScrubbing = true
        playheadScrubClampToLoop = false
        // Playing (not recording): stop players and freeze the clock; one seek on finger-up.
        if isPlaying, !isRecording {
            resumePlaybackAfterPlayheadScrub = true
            suppressLoopWrapUntilStop = true
            instrumentalPlayer.stop()
            metronomePlayer.stop()
            stopClipPlayers()
            playbackStartedHostTime = nil
            return
        }
        // Recording or idle: move playhead during drag; seek once on end if transport is live.
        resumePlaybackAfterPlayheadScrub = isPlaying || isRecording
    }

    /// Move playhead during a scrub drag without rebuilding players.
    func updatePlayheadScrub(to seconds: Double, clampToLoop: Bool = false) {
        playheadScrubClampToLoop = clampToLoop
        var target = max(0, seconds)
        if clampToLoop, loopEnabled, regionDurationSeconds > 0 {
            let regionEnd = regionStartSeconds + regionDurationSeconds
            target = min(max(target, regionStartSeconds), max(regionStartSeconds, regionEnd - 0.001))
        }
        playheadSeconds = target
    }

    /// Finish scrub drag — one seek/resync if transport was live.
    func endPlayheadScrub() {
        guard isPlayheadScrubbing else { return }
        isPlayheadScrubbing = false
        let shouldResume = resumePlaybackAfterPlayheadScrub
        resumePlaybackAfterPlayheadScrub = false
        if shouldResume, isPlaying || isRecording, !isCountingIn {
            seekPlayhead(to: playheadSeconds, clampToLoop: playheadScrubClampToLoop)
        }
    }

    func setLoopBoundaryHandler(_ handler: (() -> Void)?) {
        onLoopBoundary = handler
    }

    func setRecordingPunchInHandler(_ handler: (() -> Void)?) {
        onRecordingPunchIn = handler
    }

    // MARK: - Playback

    func play(fromRegionStart: Bool = true, armRecordingOnStart: Bool = true) throws {
        try startEngineIfNeeded()
        // Duck monitor while rebuilding players — churn under a live mic → static/distortion.
        let restoreMonitor = isRecording || desiredMonitorEnabled || wantsInputMetering
            || vocalMonitorMixer.outputVolume > 0.001
        vocalMonitorMixer.outputVolume = 0

        stopPlayers(keepEngine: true)
        guard ensureEngineRunning() else {
            if restoreMonitor { applyDesiredMonitor() }
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
        scheduleMetronomeClicks(from: playheadSeconds)

        guard ensureEngineRunning() else {
            if restoreMonitor { applyDesiredMonitor() }
            throw NSError(
                domain: "LoopFlow",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Audio engine failed to start"]
            )
        }

        let startHost = startTransportPlayers(clipCount: scheduledClipCount, at: playheadSeconds)

        isPlaying = true
        isCountingIn = false
        loopBoundaryArmed = true
        suppressLoopWrapUntilStop = false
        // Start mic writes only once the musical clock is running (avoids pre-roll silence).
        if armRecordingOnStart {
            armRecordingWritesAlignedToClock(atHostTime: startHost)
        }
        // Re-assert monitor after player churn / session work.
        if restoreMonitor || isRecording {
            applyDesiredMonitor()
        }
        startDisplayLink()
    }

    func stop() {
        onRecordingPunchIn = nil
        stopRecordingTap()
        stopPlayers(keepEngine: true)
        isPlaying = false
        isRecording = false
        isCountingIn = false
        loopBoundaryArmed = false
        suppressLoopWrapUntilStop = false
        isPlayheadScrubbing = false
        resumePlaybackAfterPlayheadScrub = false
        transportReanchorPending = false
        playbackStartedHostTime = nil
        // Keep the display link for tap metering when Input Monitor / meter is still armed.
        if wantsInputMetering || desiredMonitorEnabled || inputTapInstalled {
            if displayLink == nil {
                startDisplayLink()
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
            inputLevel = 0
            tapPeakLevel = 0
        }
        // Release sticky capture only when the mic path is fully idle.
        if !desiredMonitorEnabled && !wantsInputMetering {
            releaseCaptureHold()
        }
        flushPendingClipHardRefreshIfNeeded()
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
        for i in clipPlayers.indices {
            clipPlayers[i].stop()
            clipPlayers[i].volume = 1
            clipPlayerScheduledClips[i] = nil
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

    /// Lead before the shared player start — must exceed one render quantum so `play(at:)`
    /// lands on a future render cycle for every player.
    private static let transportStartLeadSeconds: TimeInterval = 0.03

    /// Start instrumental + scheduled clip players + metronome at ONE shared host time.
    /// Bare `play()` starts each node at the render cycle after that call, so a sequential
    /// start shifts the metronome 1+ quanta behind the bed once clip players sit in between
    /// (clicks audibly late whenever recordings play, worse with more clips). A shared
    /// `play(at:)` gives every player-relative schedule the exact same sample zero, and the
    /// playhead clock is anchored to that same instant. Returns the shared start host time.
    @discardableResult
    private func startTransportPlayers(clipCount: Int, at timelineSeconds: Double) -> UInt64 {
        let startHost = mach_absolute_time() &+ Self.secondsToHostTicks(Self.transportStartLeadSeconds)
        let when = AVAudioTime(hostTime: startHost)
        instrumentalPlayer.play(at: when)
        let n = min(clipCount, clipPlayers.count)
        for i in 0..<n where !clipPlayers[i].isPlaying {
            clipPlayers[i].play(at: when)
        }
        metronomePlayer.play(at: when)
        anchorPlaybackClock(at: timelineSeconds, hostTime: startHost)
        Self.transportLog.debug(
            "shared start: t=\(timelineSeconds, format: .fixed(precision: 3))s lead=\(Self.transportStartLeadSeconds * 1000, format: .fixed(precision: 0))ms clips=\(n)"
        )
        return startHost
    }

    private func audioFile(for url: URL, playerIndex: Int) -> AVAudioFile? {
        if let cached = clipFileCache[playerIndex], cached.url == url {
            return cached.file
        }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        clipFileCache[playerIndex] = (url, file)
        return file
    }

    @discardableResult
    private func scheduleClips(at timelineSeconds: Double) -> Int {
        let windowEnd = playbackWindowEnd
        var playerIndex = 0
        for clip in scheduledClips {
            guard playerIndex < clipPlayers.count else { break }
            guard let file = audioFile(for: clip.url, playerIndex: playerIndex) else { continue }
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
            player.pan = max(-1, min(1, clip.pan))
            clipPlayerScheduledClips[playerIndex] = clip
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

        // Player-relative time (nil = now when play() starts). Absolute render times mute stopped nodes.
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

        // While recording, always wrap the take loop — even if arrangement loop UI is off.
        // Stopping here would leave RecordingManager.phase out of sync with isRecording.
        if loopEnabled || isRecording {
            playheadSeconds = regionStartSeconds
            onLoopBoundary?()
            instrumentalPlayer.stop()
            metronomePlayer.stop()
            stopClipPlayers()
            guard ensureEngineRunning() else { return }
            scheduleInstrumentalSegment(at: regionStartSeconds)
            let count = scheduleClips(at: regionStartSeconds)
            scheduleMetronomeClicks(from: regionStartSeconds)
            let startHost = startTransportPlayers(clipCount: count, at: regionStartSeconds)
            loopBoundaryArmed = true
            armRecordingWritesAlignedToClock(atHostTime: startHost)
            if isRecording {
                applyDesiredMonitor()
            }
        } else {
            stop()
        }
    }

    // MARK: - Metronome / Count-in

    private var clickBuffer: AVAudioPCMBuffer?
    /// Louder copy of `clickBuffer` for downbeats (per-buffer level; player volume is global).
    private var accentClickBuffer: AVAudioPCMBuffer?
    /// Bound on pre-scheduled clicks per transport start (~8.5 min at 120 BPM).
    private static let maxScheduledClicks = 1024

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
        accentClickBuffer = nil
    }

    private func accentBuffer(matching click: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        if let existing = accentClickBuffer,
           existing.format.channelCount == click.format.channelCount,
           abs(existing.format.sampleRate - click.format.sampleRate) < 1 {
            return existing
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: click.format, frameCapacity: click.frameLength) else {
            return click
        }
        copy.frameLength = click.frameLength
        for ch in 0..<Int(click.format.channelCount) {
            guard let src = click.floatChannelData?[ch], let dst = copy.floatChannelData?[ch] else { continue }
            for i in 0..<Int(click.frameLength) {
                dst[i] = max(-1, min(1, src[i] * 1.6))
            }
        }
        accentClickBuffer = copy
        return copy
    }

    /// Pre-schedule clicks on the metronome player's sample timeline so they share the exact
    /// zero of the bed/clip schedules. Display-link clicks drift under main-thread load —
    /// which grows with kept clips/autosaves and made later phrases progressively late.
    /// Always scheduled; enable/disable is a mixer mute so toggling never touches transport.
    private func scheduleMetronomeClicks(from timelineSeconds: Double) {
        ensureClickBuffer()
        guard let click = clickBuffer else { return }
        let beatDuration = TimelineManager.secondsPerBeat(bpm: bpm)
        guard beatDuration > 0.001 else { return }
        let windowEnd = playbackWindowEnd
        guard windowEnd > timelineSeconds + 0.001 else { return }
        let playerRate = metronomePlayer.outputFormat(forBus: 0).sampleRate
        let rate = playerRate > 0 ? playerRate : click.format.sampleRate
        guard rate > 0 else { return }
        let accent = accentBuffer(matching: click)
        let beatsPerBar = max(1, timeSignature.beatsPerBar)

        // First beat at or after the start position (a beat exactly on it plays immediately).
        var beatIndex = Int(((timelineSeconds - 0.000_5) / beatDuration).rounded(.up))
        beatIndex = max(0, beatIndex)
        var scheduled = 0
        while scheduled < Self.maxScheduledClicks {
            let beatTime = Double(beatIndex) * beatDuration
            if beatTime >= windowEnd - 0.000_5 { break }
            let delay = beatTime - timelineSeconds
            let when: AVAudioTime? = delay > 0.000_5
                ? AVAudioTime(sampleTime: AVAudioFramePosition(delay * rate), atRate: rate)
                : nil
            let buffer = beatIndex % beatsPerBar == 0 ? accent : click
            metronomePlayer.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
            beatIndex += 1
            scheduled += 1
        }
    }

    func startCountIn(beats: Int, completion: @escaping () -> Void) throws {
        try startEngineIfNeeded()
        countInBeatsRemaining = beats
        lastMetronomeBeat = -1
        isCountingIn = true
        isPlaying = true
        playheadSeconds = regionStartSeconds
        onCountInFinished = completion
        anchorPlaybackClock(at: 0)
        // Count-in must be audible even with metro off — unmute the mixer directly so the
        // user's metronome preference is restored (not overwritten) when the take starts.
        metronomeMixer.outputVolume = 0.55
        startDisplayLink()
        ensureClickBuffer()
    }

    // MARK: - Recording tap + metering

    func beginRecording(to url: URL) throws {
        // Always capture — do not probe the session with isRecording==false (that
        // flips default↔measurement and leaves a stale mic graph with volume up / silence).
        try configureSession(forMonitoring: true)
        prepareInputCapture()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        reconnectMetronomeWithHardwareFormat()

        // Reuse a healthy mic+tap path. Tearing it down under (or just before) live
        // monitor is what distorts overdubs over kept takes — and the WAV.
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        let pathHealthy = inputTapInstalled
            && micPathSampleRate > 0
            && inputFormat.sampleRate > 0
            && abs(micPathSampleRate - inputFormat.sampleRate) < 1
        if !pathHealthy {
            if inputTapInstalled {
                micSplitter.removeTap(onBus: 0)
                inputTapInstalled = false
            }
            micPathSampleRate = 0
        }

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
            clipFileCache = clipFileCache.filter { $0.value.url != url }
            try FileManager.default.removeItem(at: url)
        }
        recordingFile = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        recordingFileForTap = recordingFile
        recordingWriteFormat = fileFormat
        micTapFormat = hwFormat
        if hwFormat != fileFormat {
            recordingConverter = AVAudioConverter(from: hwFormat, to: fileFormat)
        } else {
            recordingConverter = nil
        }
        recordingWriteEnabled = false
        isRecording = true
        holdCaptureSession = true
        syncInputTap()
        // Hear yourself while recording when on headphones/BT (even if I is off).
        applyDesiredMonitor()
    }

    func rotateRecordingFile(to url: URL) throws {
        // Stop tap writes so the previous WAV can finalize its header.
        recordingWriteEnabled = false
        recordingFileForTap = nil
        recordingFile = nil

        // Match the installed tap format — fresh inputNode queries can disagree mid-session.
        let hwFormat = micTapFormat ?? engine.inputNode.inputFormat(forBus: 0)
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
        } else {
            recordingConverter = nil
        }
        // Leave writes off until the musical clock restarts (play / seek / loop wrap).
        recordingWriteEnabled = false
    }

    /// Enable mic file writes aligned to the musical clock (and refresh latency stamp).
    /// Pass the shared player-start host time so WAV sample 0 trims to the audible zero.
    func armRecordingWritesAlignedToClock(atHostTime hostTime: UInt64? = nil) {
        guard isRecording, recordingFile != nil else { return }
        // Lead-in: keep writes gated until the playhead reaches the loop region.
        if onRecordingPunchIn != nil, playheadSeconds < regionStartSeconds - 0.0001 {
            return
        }
        activeRecordingLatencySeconds = roundTripLatencySeconds
        recordingWriteSkewSeconds = -1
        recordingArmHostTime = hostTime ?? mach_absolute_time()
        recordingWriteEnabled = true
        let anchorToArmMs: Double
        if let anchor = playbackStartedHostTime, recordingArmHostTime >= anchor {
            anchorToArmMs = Self.hostTimeToSeconds(recordingArmHostTime &- anchor) * 1000
        } else {
            anchorToArmMs = -1
        }
        Self.transportLog.info(
            "arm writes: latency=\(self.activeRecordingLatencySeconds * 1000, format: .fixed(precision: 1))ms anchor→arm=\(anchorToArmMs, format: .fixed(precision: 2))ms"
        )
        if let punch = onRecordingPunchIn {
            onRecordingPunchIn = nil
            punch()
        }
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
        flushPendingClipHardRefreshIfNeeded()
    }

    private func syncInputTap() {
        let needTap = isRecording || recordingFile != nil || wantsInputMetering || holdCaptureSession
        if needTap {
            installInputTapIfNeeded()
        } else if inputTapInstalled {
            micSplitter.removeTap(onBus: 0)
            inputTapInstalled = false
            micTapFormat = nil
        }
    }

    private func installInputTapIfNeeded() {
        guard !inputTapInstalled else { return }
        guard let format = connectMicPathIfNeeded() else {
            errorMessage = "Mic unavailable (format 0) — check permissions / route"
            return
        }

        // Tap splitter (not inputNode) so hardware passthrough stays audible.
        // No MainActor hops from this callback — they glitch monitor + WAV together.
        micSplitter.installTap(onBus: 0, bufferSize: Self.recordingTapBufferFrames, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.tapPeakLevel = Self.bufferPeakLevel(buffer)
            if self.recordingWriteEnabled {
                var outBuffer = buffer
                let isFirstWrite = self.recordingWriteSkewSeconds < 0 && self.recordingArmHostTime != 0
                if isFirstWrite {
                    // Align WAV sample 0 to the arm instant: drop frames captured before arm.
                    // Without this every region starts up to one tap quantum early/late and
                    // Keep placement varies region to region.
                    guard let trimmed = Self.bufferTrimmedToArm(
                        buffer,
                        capturedAt: when,
                        armHostTime: self.recordingArmHostTime
                    ) else {
                        return // Entire buffer predates arm — wait for the next one.
                    }
                    outBuffer = trimmed
                    let delta = mach_absolute_time() &- self.recordingArmHostTime
                    self.recordingWriteSkewSeconds = Self.hostTimeToSeconds(delta)
                }
                _ = Self.writeRecordingBuffer(
                    outBuffer,
                    file: self.recordingFileForTap,
                    converter: self.recordingConverter,
                    writeFormat: self.recordingWriteFormat
                ) { message in
                    self.pendingTapError = message
                }
            }
        }
        inputTapInstalled = true
        micTapFormat = format
        if displayLink == nil {
            startDisplayLink()
        }
        _ = ensureEngineRunning()
    }

    /// Publish tap peak / errors on the main-thread display link (never from the audio tap).
    private func publishTapMetering() {
        if let message = pendingTapError {
            pendingTapError = nil
            errorMessage = message
        }
        guard inputTapInstalled || isRecording || wantsInputMetering else { return }
        smoothInputLevel(tapPeakLevel)
    }

    /// First tap buffer after write-arm: drop frames captured before the arm instant so the
    /// file's sample 0 corresponds to the musical zero. Returns nil when the entire buffer
    /// predates arm (caller waits for the next one); returns the input unchanged when the
    /// capture timestamp is unavailable or no trim is needed.
    private nonisolated static func bufferTrimmedToArm(
        _ buffer: AVAudioPCMBuffer,
        capturedAt when: AVAudioTime,
        armHostTime: UInt64
    ) -> AVAudioPCMBuffer? {
        guard when.isHostTimeValid else { return buffer }
        let rate = buffer.format.sampleRate
        let frames = buffer.frameLength
        guard rate > 0, frames > 0 else { return buffer }
        guard armHostTime > when.hostTime else { return buffer }
        let aheadSeconds = hostTimeToSeconds(armHostTime &- when.hostTime)
        let dropFrames = AVAudioFrameCount(min(Double(frames), (aheadSeconds * rate).rounded()))
        guard dropFrames > 0 else { return buffer }
        guard dropFrames < frames else { return nil }
        let keepFrames = frames - dropFrames
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: keepFrames) else {
            return buffer
        }
        trimmed.frameLength = keepFrames
        let channels = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            let offset = Int(dropFrames) * channels
            let count = Int(keepFrames) * channels
            if let src = buffer.floatChannelData?[0], let dst = trimmed.floatChannelData?[0] {
                dst.update(from: src + offset, count: count)
            } else if let src = buffer.int16ChannelData?[0], let dst = trimmed.int16ChannelData?[0] {
                dst.update(from: src + offset, count: count)
            } else {
                return buffer
            }
        } else {
            for ch in 0..<channels {
                if let src = buffer.floatChannelData?[ch], let dst = trimmed.floatChannelData?[ch] {
                    dst.update(from: src + Int(dropFrames), count: Int(keepFrames))
                } else if let src = buffer.int16ChannelData?[ch], let dst = trimmed.int16ChannelData?[ch] {
                    dst.update(from: src + Int(dropFrames), count: Int(keepFrames))
                } else {
                    return buffer
                }
            }
        }
        return trimmed
    }

    @discardableResult
    private nonisolated static func writeRecordingBuffer(
        _ buffer: AVAudioPCMBuffer,
        file: AVAudioFile?,
        converter: AVAudioConverter?,
        writeFormat: AVAudioFormat?,
        onError: (String) -> Void
    ) -> Bool {
        guard let file, buffer.frameLength > 0 else { return false }
        do {
            if let converter, let writeFormat {
                guard let outBuffer = AVAudioPCMBuffer(
                    pcmFormat: writeFormat,
                    frameCapacity: buffer.frameLength
                ) else { return false }
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
                    return false
                }
                try file.write(from: outBuffer)
            } else {
                try file.write(from: buffer)
            }
            return true
        } catch {
            onError(error.localizedDescription)
            return false
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

    /// Anchor playhead/metro to the moment players start (matches player-relative schedules).
    /// Pass the shared `play(at:)` host time so the display clock equals the audible start.
    private func anchorPlaybackClock(at timelineSeconds: Double, hostTime: UInt64? = nil) {
        playbackStartedOffset = timelineSeconds
        playbackStartedHostTime = hostTime ?? mach_absolute_time()
        transportReanchorPending = false
        Self.transportLog.debug("anchor: t=\(timelineSeconds, format: .fixed(precision: 3))s")
    }

    /// Elapsed seconds on the audio sample clock from a running player (resets to ~0 after each play/seek).
    private func playerTransportElapsedSeconds() -> Double? {
        let candidates: [AVAudioPlayerNode] = [instrumentalPlayer] + clipPlayers + [metronomePlayer]
        for player in candidates {
            guard player.isPlaying,
                  let nodeTime = player.lastRenderTime,
                  nodeTime.isSampleTimeValid,
                  let playerTime = player.playerTime(forNodeTime: nodeTime),
                  playerTime.isSampleTimeValid,
                  playerTime.sampleRate > 0,
                  playerTime.sampleTime >= 0
            else { continue }
            return Double(playerTime.sampleTime) / playerTime.sampleRate
        }
        return nil
    }

    /// Elapsed transport seconds since the playback anchor (prefer audio player time).
    private func transportElapsedSeconds() -> Double? {
        if let audioElapsed = playerTransportElapsedSeconds() {
            return audioElapsed
        }
        guard let start = playbackStartedHostTime else { return nil }
        let now = mach_absolute_time()
        guard now >= start else { return 0 }
        return Self.hostTimeToSeconds(now &- start)
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func displayTick() {
        publishTapMetering()
        // A ruler scrub owns the playhead, and a region jump must not derive a position from
        // the old players' sample clock before the handoff re-anchors.
        if isPlayheadScrubbing || transportReanchorPending { return }
        guard let elapsed = transportElapsedSeconds() else { return }

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
                // Count-in unmuted the click mixer directly; restore the user's preference.
                setMetronomeVolume(metronomeEnabled)
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

            // Punch-in after lead-in: arm mic writes when the playhead enters the loop region.
            if isRecording, onRecordingPunchIn != nil, !recordingWriteEnabled,
               position >= regionStartSeconds - 0.0001 {
                playheadSeconds = max(position, regionStartSeconds)
                armRecordingWritesAlignedToClock()
            }

            // Loop wrap only when playing through the loop end — not when starting past it
            // or after the user scrubbed the playhead during this transport run.
            let shouldWrapLoop = (loopEnabled || isRecording)
                && !suppressLoopWrapUntilStop
                && position >= regionEnd
                && playbackStartedOffset < regionEnd - 0.001

            if shouldWrapLoop {
                handleLoopBoundary()
                // After boundary, playhead/host clock are reset; show region start this frame.
                playheadSeconds = regionStartSeconds
            } else {
                playheadSeconds = position
                let stopAt: Double
                if isRecording {
                    stopAt = regionEnd
                } else if suppressLoopWrapUntilStop {
                    stopAt = max(arrangementEndSeconds, playbackStartedOffset + 0.05)
                } else {
                    stopAt = max(regionEnd, arrangementEndSeconds, playbackStartedOffset + 0.05)
                }
                if position >= stopAt {
                    stop()
                    return
                }
            }
            // Metronome clicks are pre-scheduled on the player sample timeline (see
            // scheduleMetronomeClicks) — no display-link clicks during play/record.
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

    private nonisolated static func hostTimeToSeconds(_ delta: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = Double(delta) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000
    }

    private nonisolated static func secondsToHostTicks(_ seconds: TimeInterval) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = max(0, seconds) * 1_000_000_000
        return UInt64(nanos * Double(info.denom) / Double(info.numer))
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
