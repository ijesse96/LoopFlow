import Foundation

enum TrackType: String, Codable, CaseIterable {
    case instrumental
    case vocal
    case audio
}

struct EffectSlotState: Codable, Equatable, Identifiable {
    var id: UUID
    var typeName: String
    var bypass: Bool
    var parameters: [String: Double]

    init(
        id: UUID = UUID(),
        typeName: String = "Empty",
        bypass: Bool = true,
        parameters: [String: Double] = [:]
    ) {
        self.id = id
        self.typeName = typeName
        self.bypass = bypass
        self.parameters = parameters
    }
}

struct Track: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var type: TrackType
    var isMuted: Bool
    var isSoloed: Bool
    /// Live mic input monitor (hear-yourself) for vocal/audio tracks.
    var inputMonitorEnabled: Bool
    var volume: Float
    var pan: Float
    var effectSlots: [EffectSlotState]
    var takes: [Take]
    var clips: [AudioClip]
    /// Relative path for instrumental / fixed audio clip.
    var audioRelativePath: String?
    var waveformPeaks: [Float]

    init(
        id: UUID = UUID(),
        name: String,
        type: TrackType,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        inputMonitorEnabled: Bool = false,
        volume: Float = 0.85,
        pan: Float = 0,
        effectSlots: [EffectSlotState] = [EffectSlotState(), EffectSlotState(), EffectSlotState()],
        takes: [Take] = [],
        clips: [AudioClip] = [],
        audioRelativePath: String? = nil,
        waveformPeaks: [Float] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.inputMonitorEnabled = inputMonitorEnabled
        self.volume = volume
        self.pan = pan
        self.effectSlots = effectSlots
        self.takes = takes
        self.clips = clips
        self.audioRelativePath = audioRelativePath
        self.waveformPeaks = waveformPeaks
    }

    var acceptedTakes: [Take] {
        takes.filter(\.isAccepted).sorted { $0.regionIndex < $1.regionIndex }
    }

    mutating func upsertClip(_ clip: AudioClip) {
        if let idx = clips.firstIndex(where: { $0.id == clip.id }) {
            clips[idx] = clip
        } else {
            clips.append(clip)
        }
    }

    mutating func removeClip(id: UUID) {
        clips.removeAll { $0.id == id }
    }
}

extension Track {
    enum CodingKeys: String, CodingKey {
        case id, name, type, isMuted, isSoloed, inputMonitorEnabled, volume, pan
        case effectSlots, takes, clips, audioRelativePath, waveformPeaks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(TrackType.self, forKey: .type)
        isMuted = try c.decode(Bool.self, forKey: .isMuted)
        isSoloed = try c.decode(Bool.self, forKey: .isSoloed)
        inputMonitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .inputMonitorEnabled) ?? false
        volume = try c.decode(Float.self, forKey: .volume)
        pan = try c.decode(Float.self, forKey: .pan)
        effectSlots = try c.decode([EffectSlotState].self, forKey: .effectSlots)
        takes = try c.decode([Take].self, forKey: .takes)
        clips = try c.decodeIfPresent([AudioClip].self, forKey: .clips) ?? []
        audioRelativePath = try c.decodeIfPresent(String.self, forKey: .audioRelativePath)
        waveformPeaks = try c.decodeIfPresent([Float].self, forKey: .waveformPeaks) ?? []
    }
}
