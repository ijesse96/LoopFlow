import Foundation

struct KeyMapping: Codable, Equatable, Identifiable {
    var id: String { action.rawValue }
    var action: ControllerAction
    /// Hardware key code (UIKeyboardHIDUsage) or a stable string token for special keys.
    var keyCode: UInt32?
    /// Human-readable label shown in Settings.
    var keyLabel: String?

    var isAssigned: Bool { keyCode != nil }

    static func defaults() -> [KeyMapping] {
        [
            KeyMapping(action: .keepTake, keyCode: 0x04, keyLabel: "A"),           // A
            KeyMapping(action: .keepTakeAndNext, keyCode: 0x2C, keyLabel: "Space"), // Space
            KeyMapping(action: .previousRegion, keyCode: 0x50, keyLabel: "←"),      // Left
            KeyMapping(action: .nextRegion, keyCode: 0x4F, keyLabel: "→"),          // Right
            KeyMapping(action: .redoRegion, keyCode: 0x15, keyLabel: "R"),          // R
            KeyMapping(action: .undo, keyCode: 0x1D, keyLabel: "Z"),                // Z
            KeyMapping(action: .record, keyCode: 0x12, keyLabel: "O"),              // O
            KeyMapping(action: .leadIn, keyCode: nil, keyLabel: nil),
            KeyMapping(action: .stop, keyCode: 0x29, keyLabel: "Esc")               // Escape
        ]
    }
}
