import Foundation

enum RegionLength: Int, Codable, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case four = 4
    case eight = 8

    var id: Int { rawValue }

    var displayName: String {
        rawValue == 1 ? "1 Bar" : "\(rawValue) Bars"
    }
}
