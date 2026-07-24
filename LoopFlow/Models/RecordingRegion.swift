import Foundation

struct RecordingRegion: Codable, Identifiable, Equatable {
    var id: Int { index }
    var index: Int
    var startBar: Int
    var lengthBars: Int

    var endBar: Int { startBar + lengthBars }

    func startSeconds(bpm: Double, timeSignature: TimeSignature) -> Double {
        let secondsPerBeat = 60.0 / bpm
        let beatsPerBar = Double(timeSignature.beatsPerBar)
        return Double(startBar - 1) * beatsPerBar * secondsPerBeat
    }

    func durationSeconds(bpm: Double, timeSignature: TimeSignature) -> Double {
        let secondsPerBeat = 60.0 / bpm
        let beatsPerBar = Double(timeSignature.beatsPerBar)
        return Double(lengthBars) * beatsPerBar * secondsPerBeat
    }
}
