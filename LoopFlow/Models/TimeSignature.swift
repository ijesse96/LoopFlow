import Foundation

struct TimeSignature: Codable, Equatable, Hashable {
    var beatsPerBar: Int
    var beatUnit: Int

    static let fourFour = TimeSignature(beatsPerBar: 4, beatUnit: 4)

    var displayString: String {
        "\(beatsPerBar) / \(beatUnit)"
    }
}
