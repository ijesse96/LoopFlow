import Foundation

enum ControllerAction: String, Codable, CaseIterable, Identifiable {
    case keepTake
    case keepTakeAndNext
    case previousRegion
    case nextRegion
    case redoRegion
    case undo
    case record
    case stop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepTake: return "Keep Take"
        case .keepTakeAndNext: return "Keep Take + Next Region"
        case .previousRegion: return "Previous Region"
        case .nextRegion: return "Next Region"
        case .redoRegion: return "Redo Region"
        case .undo: return "Undo"
        case .record: return "Record"
        case .stop: return "Stop"
        }
    }
}
