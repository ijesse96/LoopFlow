import Foundation
import AVFoundation

enum ExportKind: String, CaseIterable, Identifiable {
    case vocal
    case instrumental
    case stems
    case fullMix

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vocal: return "Vocal"
        case .instrumental: return "Instrumental"
        case .stems: return "Stems"
        case .fullMix: return "Full Mix"
        }
    }
}

@MainActor
final class ExportManager {
    private let storage: ProjectStorageManager

    init(storage: ProjectStorageManager? = nil) {
        self.storage = storage ?? ProjectStorageManager.shared
    }

    func export(_ kind: ExportKind, project: LoopFlowProject) async throws -> [URL] {
        switch kind {
        case .vocal:
            let url = try await bounceVocal(project: project)
            return [url]
        case .instrumental:
            let url = try exportInstrumentalCopy(project: project)
            return [url]
        case .stems:
            var urls: [URL] = []
            if let inst = try? exportInstrumentalCopy(project: project) {
                urls.append(inst)
            }
            urls.append(try await bounceVocal(project: project))
            return urls
        case .fullMix:
            let url = try await bounceFullMix(project: project)
            return [url]
        }
    }

    private func exportDirectory(for project: LoopFlowProject) throws -> URL {
        let dir = storage.projectDirectory(for: project.id).appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func exportInstrumentalCopy(project: LoopFlowProject) throws -> URL {
        guard let track = project.instrumentalTrack,
              let relative = track.audioRelativePath else {
            throw ExportError.missingInstrumental
        }
        let source = storage.absoluteURL(for: relative, projectID: project.id)
        let dest = try exportDirectory(for: project).appendingPathComponent("instrumental.wav")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        if let clip = track.clips.first {
            try convertToWAV(
                source: source,
                destination: dest,
                sourceStart: clip.sourceStartSeconds,
                sourceEnd: clip.sourceEndSeconds
            )
        } else {
            try convertToWAV(source: source, destination: dest)
        }
        return dest
    }

    private func bounceVocal(project: LoopFlowProject) async throws -> URL {
        guard let vocalIdx = project.vocalTrackIndex else {
            throw ExportError.missingVocal
        }
        let clips = project.tracks[vocalIdx].clips.filter { !$0.isMuted }
        let dest = try exportDirectory(for: project).appendingPathComponent("vocal.wav")
        try await stitchClips(clips, project: project, destination: dest, includeInstrumental: false)
        return dest
    }

    private func bounceFullMix(project: LoopFlowProject) async throws -> URL {
        let dest = try exportDirectory(for: project).appendingPathComponent("full_mix.wav")
        var clips: [AudioClip] = []
        for track in project.tracks where !track.isMuted {
            clips.append(contentsOf: track.clips.filter { !$0.isMuted })
        }
        try await stitchClips(clips, project: project, destination: dest, includeInstrumental: false)
        return dest
    }

    private func stitchClips(
        _ clips: [AudioClip],
        project: LoopFlowProject,
        destination: URL,
        includeInstrumental: Bool
    ) async throws {
        let sampleRate: Double = 44_100
        let channels: AVAudioChannelCount = 2
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            throw ExportError.formatFailed
        }

        let totalDuration = max(project.instrumentalDurationSeconds, project.secondsPerBar * Double(project.totalBars))
        let totalFrames = AVAudioFrameCount(totalDuration * sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, totalFrames)) else {
            throw ExportError.formatFailed
        }
        outputBuffer.frameLength = totalFrames
        memset(outputBuffer.floatChannelData![0], 0, Int(totalFrames) * MemoryLayout<Float>.size)
        memset(outputBuffer.floatChannelData![1], 0, Int(totalFrames) * MemoryLayout<Float>.size)

        if includeInstrumental, let relative = project.instrumentalTrack?.audioRelativePath {
            let url = storage.absoluteURL(for: relative, projectID: project.id)
            try mixFile(
                url,
                into: outputBuffer,
                at: 0,
                gain: project.instrumentalTrack?.volume ?? 0.8,
                pan: project.instrumentalTrack?.pan ?? 0,
                format: format
            )
        }

        for clip in clips {
            let start = project.beatsToSeconds(clip.timelineStartBeats)
            let url = storage.absoluteURL(for: clip.sourceRelativePath, projectID: project.id)
            let track = project.tracks.first(where: { $0.id == clip.trackId })
            let trackGain = track?.volume ?? 1
            try mixFile(
                url,
                into: outputBuffer,
                at: start,
                gain: trackGain * clip.gain,
                pan: track?.pan ?? 0,
                format: format,
                sourceStart: clip.sourceStartSeconds,
                sourceEnd: clip.sourceEndSeconds
            )
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let outFile = try AVAudioFile(forWriting: destination, settings: format.settings)
        try outFile.write(from: outputBuffer)
    }

    private func mixFile(
        _ url: URL,
        into output: AVAudioPCMBuffer,
        at startSeconds: Double,
        gain: Float,
        pan: Float = 0,
        format: AVAudioFormat,
        sourceStart: Double = 0,
        sourceEnd: Double? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let rate = srcFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, sourceStart) * rate)
        let endSec = sourceEnd ?? (Double(file.length) / rate)
        let frameCount = AVAudioFrameCount(max(1, (endSec - sourceStart) * rate))
        guard frameCount > 0,
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        file.framePosition = min(startFrame, file.length)
        try file.read(into: srcBuffer, frameCount: min(frameCount, AVAudioFrameCount(file.length - file.framePosition)))

        let converted: AVAudioPCMBuffer
        if srcFormat != format {
            guard let conv = AVAudioConverter(from: srcFormat, to: format),
                  let outBuf = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(Double(srcBuffer.frameLength) * format.sampleRate / srcFormat.sampleRate + 16)
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
                return srcBuffer
            }
            conv.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
            converted = outBuf
        } else {
            converted = srcBuffer
        }

        let destStart = Int(startSeconds * format.sampleRate)
        let outL = output.floatChannelData![0]
        let outR = output.floatChannelData![1]
        let inL = converted.floatChannelData![0]
        let inR = converted.format.channelCount > 1 ? converted.floatChannelData![1] : inL
        let count = Int(converted.frameLength)
        let outCount = Int(output.frameLength)
        let clampedPan = max(-1, min(1, pan))
        let angle = (clampedPan + 1) * Float.pi / 4
        let leftGain = gain * cos(angle)
        let rightGain = gain * sin(angle)

        for i in 0..<count {
            let dest = destStart + i
            guard dest >= 0, dest < outCount else { continue }
            outL[dest] += inL[i] * leftGain
            outR[dest] += inR[i] * rightGain
        }
    }

    private func convertToWAV(
        source: URL,
        destination: URL,
        sourceStart: Double = 0,
        sourceEnd: Double? = nil
    ) throws {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        let rate = format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, sourceStart) * rate)
        let endSec = sourceEnd ?? (Double(file.length) / rate)
        let frameCount = AVAudioFrameCount(max(1, (endSec - sourceStart) * rate))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ExportError.formatFailed
        }
        file.framePosition = min(startFrame, max(0, file.length - 1))
        let readable = min(frameCount, AVAudioFrameCount(max(0, file.length - file.framePosition)))
        guard readable > 0 else { throw ExportError.formatFailed }
        try file.read(into: buffer, frameCount: readable)
        let out = try AVAudioFile(forWriting: destination, settings: format.settings)
        try out.write(from: buffer)
    }
}

enum ExportError: LocalizedError {
    case missingInstrumental
    case missingVocal
    case formatFailed

    var errorDescription: String? {
        switch self {
        case .missingInstrumental: return "No instrumental to export"
        case .missingVocal: return "No vocal track"
        case .formatFailed: return "Audio format error"
        }
    }
}
