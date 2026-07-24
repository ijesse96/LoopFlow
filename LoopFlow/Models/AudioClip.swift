import Foundation

struct AudioClip: Codable, Identifiable, Equatable {
    var id: UUID
    var trackId: UUID
    var sourceRelativePath: String
    /// Non-destructive in-point in the source file.
    var sourceStartSeconds: Double
    /// Non-destructive out-point in the source file.
    var sourceEndSeconds: Double
    /// Timeline position in beats from project start (0 = bar 1 beat 1).
    var timelineStartBeats: Double
    var gain: Float
    var pan: Float
    var isMuted: Bool
    var isLooping: Bool
    var waveformPeaks: [Float]

    init(
        id: UUID = UUID(),
        trackId: UUID,
        sourceRelativePath: String,
        sourceStartSeconds: Double = 0,
        sourceEndSeconds: Double,
        timelineStartBeats: Double = 0,
        gain: Float = 1,
        pan: Float = 0,
        isMuted: Bool = false,
        isLooping: Bool = false,
        waveformPeaks: [Float] = []
    ) {
        self.id = id
        self.trackId = trackId
        self.sourceRelativePath = sourceRelativePath
        self.sourceStartSeconds = sourceStartSeconds
        self.sourceEndSeconds = sourceEndSeconds
        self.timelineStartBeats = timelineStartBeats
        self.gain = gain
        self.pan = pan
        self.isMuted = isMuted
        self.isLooping = isLooping
        self.waveformPeaks = waveformPeaks
    }

    var sourceDurationSeconds: Double {
        max(0, sourceEndSeconds - sourceStartSeconds)
    }

    func timelineDurationBeats(bpm: Double) -> Double {
        let spb = 60.0 / max(bpm, 1)
        return sourceDurationSeconds / spb
    }

    func timelineStartBar(beatsPerBar: Int) -> Int {
        Int(timelineStartBeats / Double(max(beatsPerBar, 1))) + 1
    }

    func timelineEndBeats(bpm: Double) -> Double {
        timelineStartBeats + timelineDurationBeats(bpm: bpm)
    }
}
