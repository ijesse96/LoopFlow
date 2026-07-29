import Foundation

struct Take: Codable, Identifiable, Equatable {
    var id: UUID
    var regionIndex: Int
    var takeNumber: Int
    var relativePath: String
    var createdAt: Date
    var isAccepted: Bool
    var durationSeconds: Double
    /// Round-trip latency snapshot from when mic writes armed (0 = unknown / legacy).
    var recordedLatencySeconds: Double
    /// Playhead advance from arm → first tap write (0 = unknown / legacy).
    var recordedWriteSkewSeconds: Double

    init(
        id: UUID = UUID(),
        regionIndex: Int,
        takeNumber: Int,
        relativePath: String,
        createdAt: Date = Date(),
        isAccepted: Bool = false,
        durationSeconds: Double = 0,
        recordedLatencySeconds: Double = 0,
        recordedWriteSkewSeconds: Double = 0
    ) {
        self.id = id
        self.regionIndex = regionIndex
        self.takeNumber = takeNumber
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.isAccepted = isAccepted
        self.durationSeconds = durationSeconds
        self.recordedLatencySeconds = recordedLatencySeconds
        self.recordedWriteSkewSeconds = recordedWriteSkewSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id, regionIndex, takeNumber, relativePath, createdAt, isAccepted, durationSeconds
        case recordedLatencySeconds, recordedWriteSkewSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        regionIndex = try c.decode(Int.self, forKey: .regionIndex)
        takeNumber = try c.decode(Int.self, forKey: .takeNumber)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isAccepted = try c.decode(Bool.self, forKey: .isAccepted)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        recordedLatencySeconds = try c.decodeIfPresent(Double.self, forKey: .recordedLatencySeconds) ?? 0
        recordedWriteSkewSeconds = try c.decodeIfPresent(Double.self, forKey: .recordedWriteSkewSeconds) ?? 0
    }
}
