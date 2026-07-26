import Foundation
import AVFoundation
import Accelerate

enum TimelineManager {
    static func secondsPerBeat(bpm: Double) -> Double {
        60.0 / max(bpm, 1)
    }

    static func secondsPerBar(bpm: Double, timeSignature: TimeSignature) -> Double {
        secondsPerBeat(bpm: bpm) * Double(timeSignature.beatsPerBar)
    }

    static func timeString(seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = Int(total) % 60
        let tenths = Int((total - floor(total)) * 10)
        return String(format: "%02d:%02d.%d", minutes, secs, tenths)
    }

    static func barBeatString(seconds: Double, bpm: Double, timeSignature: TimeSignature) -> String {
        let spb = secondsPerBeat(bpm: bpm)
        let totalBeats = seconds / spb
        let beatsPerBar = Double(timeSignature.beatsPerBar)
        let bar = Int(totalBeats / beatsPerBar) + 1
        let beat = Int(totalBeats.truncatingRemainder(dividingBy: beatsPerBar)) + 1
        return "\(bar).\(beat)"
    }

    static func sampleRange(
        for region: RecordingRegion,
        bpm: Double,
        timeSignature: TimeSignature,
        sampleRate: Double
    ) -> (start: AVAudioFramePosition, length: AVAudioFrameCount) {
        let startSec = region.startSeconds(bpm: bpm, timeSignature: timeSignature)
        let dur = region.durationSeconds(bpm: bpm, timeSignature: timeSignature)
        let start = AVAudioFramePosition(startSec * sampleRate)
        let length = AVAudioFrameCount(max(1, dur * sampleRate))
        return (start, length)
    }

    /// First time (seconds) where absolute amplitude exceeds `threshold`, or `nil` if never.
    /// Used to skip leading silence so the audible start can map to bar 1.
    static func findFirstSoundTime(
        url: URL,
        threshold: Float = 0.02,
        maxScanSeconds: Double = 60
    ) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0 else { return nil }

        let totalFrames = file.length
        let maxFrames = AVAudioFrameCount(min(Double(totalFrames), maxScanSeconds * rate))
        guard maxFrames > 0 else { return nil }

        // Read in chunks to avoid loading very long files entirely.
        let chunkFrames: AVAudioFrameCount = 8_192
        var position: AVAudioFramePosition = 0
        while position < AVAudioFramePosition(maxFrames) {
            let remaining = AVAudioFrameCount(AVAudioFramePosition(maxFrames) - position)
            let toRead = min(chunkFrames, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else { return nil }
            file.framePosition = position
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                return nil
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else {
                position += AVAudioFramePosition(toRead)
                continue
            }
            let channelCount = Int(format.channelCount)
            for i in 0..<frames {
                var peak: Float = 0
                for ch in 0..<channelCount {
                    peak = max(peak, abs(channels[ch][i]))
                }
                if peak >= threshold {
                    return Double(position + AVAudioFramePosition(i)) / rate
                }
            }
            position += AVAudioFramePosition(frames)
        }
        return nil
    }

    /// Slice full-file peaks to the source window for clip waveform display.
    static func slicePeaks(
        _ peaks: [Float],
        sourceStart: Double,
        sourceEnd: Double,
        totalDuration: Double
    ) -> [Float] {
        guard !peaks.isEmpty, totalDuration > 0 else { return peaks }
        let startRatio = min(1, max(0, sourceStart / totalDuration))
        let endRatio = min(1, max(startRatio + 0.001, sourceEnd / totalDuration))
        let a = min(peaks.count - 1, max(0, Int(startRatio * Double(peaks.count))))
        let b = min(peaks.count, max(a + 1, Int(endRatio * Double(peaks.count))))
        guard a < b else { return [peaks[a]] }
        return Array(peaks[a..<b])
    }

    /// Downsample audio file into peak magnitudes for waveform drawing.
    static func generateWaveformPeaks(
        url: URL,
        targetCount: Int = 800,
        sourceStartSeconds: Double = 0,
        sourceEndSeconds: Double? = nil
    ) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, file.length > 0 else { return [] }

        let totalDuration = Double(file.length) / rate
        let startSec = min(max(0, sourceStartSeconds), max(0, totalDuration - 0.001))
        let endSec = min(max(startSec + 0.001, sourceEndSeconds ?? totalDuration), totalDuration)
        let startFrame = AVAudioFramePosition(startSec * rate)
        let framesToRead = AVAudioFrameCount(max(1, (endSec - startSec) * rate))
        guard startFrame < file.length else { return [] }

        let capacity = min(framesToRead, AVAudioFrameCount(file.length - startFrame))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return []
        }
        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: capacity)
        } catch {
            return []
        }
        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        guard !samples.isEmpty else { return [] }

        let bucketSize = max(1, samples.count / targetCount)
        var peaks: [Float] = []
        peaks.reserveCapacity(targetCount)
        var i = 0
        while i < samples.count {
            let end = min(i + bucketSize, samples.count)
            var maxVal: Float = 0
            for j in i..<end {
                maxVal = max(maxVal, abs(samples[j]))
            }
            peaks.append(maxVal)
            i = end
        }
        return peaks
    }
}
