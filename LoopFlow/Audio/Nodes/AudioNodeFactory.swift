import Foundation
import AVFoundation

/// Helpers for player / recorder / metronome nodes. Graph ownership stays in AudioEngineManager.
enum AudioNodeFactory {
    static func makeClickBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount = 2,
        frequency: Float = 1000,
        duration: Double = 0.02
    ) -> AVAudioPCMBuffer? {
        guard sampleRate > 0, channels > 0 else { return nil }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        for ch in 0..<Int(channels) {
            guard let data = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frameCount) {
                let t = Float(i) / Float(sampleRate)
                let env = exp(-t * 80)
                data[i] = sin(2 * .pi * frequency * t) * env * 0.6
            }
        }
        return buffer
    }
}
