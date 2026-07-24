import Foundation

struct LoopFlowProject: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bpm: Double
    var timeSignature: TimeSignature
    var musicalKey: MusicalKey
    /// Quick-select preset for selection length (1/2/4/8).
    var regionLength: RegionLength
    var masterVolume: Float
    var metronomeEnabled: Bool
    var countInEnabled: Bool
    var loopEnabled: Bool
    var snapEnabled: Bool
    /// Track that receives mic recordings (non-instrumental).
    var selectedTrackId: UUID?
    /// 1-based start bar of the freeform recording selection.
    var selectionStartBar: Int
    /// Length of the freeform recording selection in bars.
    var selectionLengthBars: Int
    var tracks: [Track]
    var keyMappings: [KeyMapping]
    var createdAt: Date
    var updatedAt: Date
    var instrumentalDurationSeconds: Double

    init(
        id: UUID = UUID(),
        name: String = "New Project",
        bpm: Double = 120,
        timeSignature: TimeSignature = .fourFour,
        musicalKey: MusicalKey = .c,
        regionLength: RegionLength = .four,
        masterVolume: Float = 0.9,
        metronomeEnabled: Bool = true,
        countInEnabled: Bool = true,
        loopEnabled: Bool = true,
        snapEnabled: Bool = true,
        selectedTrackId: UUID? = nil,
        selectionStartBar: Int = 1,
        selectionLengthBars: Int = 4,
        tracks: [Track]? = nil,
        keyMappings: [KeyMapping] = KeyMapping.defaults(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        instrumentalDurationSeconds: Double = 0
    ) {
        self.id = id
        self.name = name
        self.bpm = bpm
        self.timeSignature = timeSignature
        self.musicalKey = musicalKey
        self.regionLength = regionLength
        self.masterVolume = masterVolume
        self.metronomeEnabled = metronomeEnabled
        self.countInEnabled = countInEnabled
        self.loopEnabled = loopEnabled
        self.snapEnabled = snapEnabled
        self.selectionStartBar = selectionStartBar
        self.selectionLengthBars = max(1, selectionLengthBars)
        self.tracks = tracks ?? [
            Track(name: "Instrumental", type: .instrumental, volume: 0.8),
            Track(name: "Vocal", type: .vocal, volume: 0.9)
        ]
        self.selectedTrackId = selectedTrackId
        self.keyMappings = keyMappings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.instrumentalDurationSeconds = instrumentalDurationSeconds
        ensureSelectedTrack()
    }

    var instrumentalTrack: Track? {
        tracks.first { $0.type == .instrumental }
    }

    var vocalTrackIndex: Int? {
        tracks.firstIndex { $0.type == .vocal }
    }

    /// Index of the track that should receive recordings.
    var recordingTrackIndex: Int? {
        if let id = selectedTrackId,
           let idx = tracks.firstIndex(where: { $0.id == id }),
           tracks[idx].type != .instrumental {
            return idx
        }
        return vocalTrackIndex
            ?? tracks.firstIndex(where: { $0.type != .instrumental })
    }

    var selectedTrack: Track? {
        guard let id = selectedTrackId else { return nil }
        return tracks.first { $0.id == id }
    }

    mutating func ensureSelectedTrack() {
        if let id = selectedTrackId, tracks.contains(where: { $0.id == id }) {
            return
        }
        if let vocal = tracks.first(where: { $0.type == .vocal }) {
            selectedTrackId = vocal.id
        } else if let other = tracks.first(where: { $0.type != .instrumental }) {
            selectedTrackId = other.id
        } else {
            selectedTrackId = tracks.first?.id
        }
    }

    var secondsPerBeat: Double {
        60.0 / max(bpm, 1)
    }

    var secondsPerBar: Double {
        secondsPerBeat * Double(timeSignature.beatsPerBar)
    }

    var totalBars: Int {
        let content = contentEndBar
        guard content > 1 || instrumentalDurationSeconds > 0 || tracks.contains(where: { !$0.clips.isEmpty }) else {
            return max(selectionLengthBars * 4, 16)
        }
        return max(content, selectionLengthBars, 1)
    }

    /// Recording loop derived from freeform selection.
    var currentRegion: RecordingRegion {
        let start = min(max(1, selectionStartBar), max(1, totalBars))
        let maxLen = max(1, totalBars - start + 1)
        let length = min(max(1, selectionLengthBars), maxLen)
        return RecordingRegion(index: 0, startBar: start, lengthBars: length)
    }

    var selectionEndBar: Int {
        currentRegion.endBar
    }

    mutating func applySelectionPreset(_ length: RegionLength) {
        regionLength = length
        selectionLengthBars = length.rawValue
        let maxStart = max(1, totalBars - selectionLengthBars + 1)
        selectionStartBar = min(selectionStartBar, maxStart)
    }

    mutating func setSelection(startBar: Int, endBarInclusive: Int) {
        let a = min(max(1, startBar), totalBars)
        let b = min(max(1, endBarInclusive), totalBars)
        selectionStartBar = min(a, b)
        selectionLengthBars = max(1, abs(b - a) + 1)
    }

    mutating func advanceSelection() {
        let next = selectionStartBar + selectionLengthBars
        if next > totalBars {
            return
        }
        selectionStartBar = next
        let maxLen = totalBars - selectionStartBar + 1
        selectionLengthBars = min(selectionLengthBars, maxLen)
    }

    mutating func retreatSelection() {
        let prev = selectionStartBar - selectionLengthBars
        selectionStartBar = max(1, prev)
    }

    func beatsToSeconds(_ beats: Double) -> Double {
        beats * secondsPerBeat
    }

    func secondsToBeats(_ seconds: Double) -> Double {
        seconds / secondsPerBeat
    }

    func barToBeats(_ bar: Int) -> Double {
        Double(max(0, bar - 1) * timeSignature.beatsPerBar)
    }

    /// Snap `beats` to the nearest multiple of `stepBeats` (e.g. bar, beat, or 1/4 beat).
    func snapBeats(_ beats: Double, stepBeats: Double = 1) -> Double {
        guard snapEnabled else { return beats }
        let step = max(stepBeats, 0.000_1)
        return (beats / step).rounded() * step
    }

    /// End of the arranged content in bars (clips preferred, then raw instrumental duration).
    var contentEndBar: Int {
        let beatsPerBar = Double(max(timeSignature.beatsPerBar, 1))
        var endBeats = 0.0
        for track in tracks {
            for clip in track.clips where !clip.isMuted {
                endBeats = max(endBeats, clip.timelineEndBeats(bpm: bpm))
            }
        }
        if endBeats <= 0, instrumentalDurationSeconds > 0 {
            endBeats = secondsToBeats(instrumentalDurationSeconds)
        }
        return max(1, Int(ceil(endBeats / beatsPerBar)))
    }

    /// Migrate legacy takes / instrumental path into clips if needed.
    mutating func ensureClipsMigrated() {
        for i in tracks.indices {
            if tracks[i].type == .instrumental,
               let path = tracks[i].audioRelativePath,
               tracks[i].clips.isEmpty,
               instrumentalDurationSeconds > 0 {
                tracks[i].clips = [
                    AudioClip(
                        trackId: tracks[i].id,
                        sourceRelativePath: path,
                        sourceStartSeconds: 0,
                        sourceEndSeconds: instrumentalDurationSeconds,
                        timelineStartBeats: 0,
                        waveformPeaks: tracks[i].waveformPeaks
                    )
                ]
            }
            if tracks[i].type == .vocal {
                for take in tracks[i].acceptedTakes {
                    let already = tracks[i].clips.contains { $0.sourceRelativePath == take.relativePath }
                    if already { continue }
                    let startBeats = Double(take.regionIndex) * Double(regionLength.rawValue) * Double(timeSignature.beatsPerBar)
                    tracks[i].clips.append(
                        AudioClip(
                            trackId: tracks[i].id,
                            sourceRelativePath: take.relativePath,
                            sourceStartSeconds: 0,
                            sourceEndSeconds: max(take.durationSeconds, secondsPerBar * Double(regionLength.rawValue)),
                            timelineStartBeats: startBeats
                        )
                    )
                }
            }
        }
    }
}

// Custom decode for backward compatibility with older project.json
extension LoopFlowProject {
    enum CodingKeys: String, CodingKey {
        case id, name, bpm, timeSignature, musicalKey, regionLength, masterVolume
        case metronomeEnabled, countInEnabled, loopEnabled, snapEnabled, selectedTrackId
        case selectionStartBar, selectionLengthBars, currentRegionIndex
        case tracks, keyMappings, createdAt, updatedAt, instrumentalDurationSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bpm = try c.decode(Double.self, forKey: .bpm)
        timeSignature = try c.decode(TimeSignature.self, forKey: .timeSignature)
        musicalKey = try c.decode(MusicalKey.self, forKey: .musicalKey)
        regionLength = try c.decode(RegionLength.self, forKey: .regionLength)
        masterVolume = try c.decode(Float.self, forKey: .masterVolume)
        metronomeEnabled = try c.decode(Bool.self, forKey: .metronomeEnabled)
        countInEnabled = try c.decode(Bool.self, forKey: .countInEnabled)
        loopEnabled = try c.decode(Bool.self, forKey: .loopEnabled)
        snapEnabled = try c.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? true
        selectedTrackId = try c.decodeIfPresent(UUID.self, forKey: .selectedTrackId)
        tracks = try c.decode([Track].self, forKey: .tracks)
        keyMappings = try c.decode([KeyMapping].self, forKey: .keyMappings)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        instrumentalDurationSeconds = try c.decode(Double.self, forKey: .instrumentalDurationSeconds)

        if let start = try c.decodeIfPresent(Int.self, forKey: .selectionStartBar),
           let length = try c.decodeIfPresent(Int.self, forKey: .selectionLengthBars) {
            selectionStartBar = start
            selectionLengthBars = max(1, length)
        } else if let idx = try c.decodeIfPresent(Int.self, forKey: .currentRegionIndex) {
            selectionLengthBars = regionLength.rawValue
            selectionStartBar = idx * regionLength.rawValue + 1
        } else {
            selectionStartBar = 1
            selectionLengthBars = regionLength.rawValue
        }
        ensureSelectedTrack()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(timeSignature, forKey: .timeSignature)
        try c.encode(musicalKey, forKey: .musicalKey)
        try c.encode(regionLength, forKey: .regionLength)
        try c.encode(masterVolume, forKey: .masterVolume)
        try c.encode(metronomeEnabled, forKey: .metronomeEnabled)
        try c.encode(countInEnabled, forKey: .countInEnabled)
        try c.encode(loopEnabled, forKey: .loopEnabled)
        try c.encode(snapEnabled, forKey: .snapEnabled)
        try c.encodeIfPresent(selectedTrackId, forKey: .selectedTrackId)
        try c.encode(selectionStartBar, forKey: .selectionStartBar)
        try c.encode(selectionLengthBars, forKey: .selectionLengthBars)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(keyMappings, forKey: .keyMappings)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(instrumentalDurationSeconds, forKey: .instrumentalDurationSeconds)
    }
}
