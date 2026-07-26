import Foundation
import UIKit
import GameController

@MainActor
final class ControllerInputManager: ObservableObject {
    @Published var isAssigning = false
    @Published var assigningAction: ControllerAction?
    @Published var lastKeyLabel: String?

    var mappings: [KeyMapping] = KeyMapping.defaults()
    var onAction: ((ControllerAction) -> Void)?

    private var keyboardObservers: [Any] = []

    init() {
        startListening()
    }

    deinit {
        // Observers cleaned on MainActor teardown; GCKeyboard uses NotificationCenter
    }

    func updateMappings(_ mappings: [KeyMapping]) {
        var merged = mappings
        for action in ControllerAction.allCases {
            if !merged.contains(where: { $0.action == action }) {
                merged.append(KeyMapping(action: action, keyCode: nil, keyLabel: nil))
            }
        }
        // Keep defaults order for stable Settings UI.
        let order = Dictionary(uniqueKeysWithValues: ControllerAction.allCases.enumerated().map { ($1, $0) })
        self.mappings = merged.sorted { (order[$0.action] ?? 0) < (order[$1.action] ?? 0) }
    }

    func startListening() {
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.attachKeyboardHandlers() }
        }
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { _ in }

        attachKeyboardHandlers()
    }

    private func attachKeyboardHandlers() {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }
        keyboard.keyChangedHandler = { [weak self] _, key, keyCode, pressed in
            guard pressed else { return }
            Task { @MainActor in
                let code = UInt32(keyCode.rawValue)
                self?.handleKey(code: code, label: key.localizedName)
            }
        }
    }

    func beginAssign(action: ControllerAction) {
        assigningAction = action
        isAssigning = true
        lastKeyLabel = nil
    }

    func cancelAssign() {
        isAssigning = false
        assigningAction = nil
    }

    func clearMapping(action: ControllerAction) {
        if let idx = mappings.firstIndex(where: { $0.action == action }) {
            mappings[idx].keyCode = nil
            mappings[idx].keyLabel = nil
        }
    }

    func resetDefaults() {
        mappings = KeyMapping.defaults()
    }

    func handleKey(code: UInt32, label: String?) {
        lastKeyLabel = label ?? "Key \(code)"

        if isAssigning, let action = assigningAction {
            // Remove duplicate bindings for same key
            for i in mappings.indices where mappings[i].keyCode == code {
                mappings[i].keyCode = nil
                mappings[i].keyLabel = nil
            }
            if let idx = mappings.firstIndex(where: { $0.action == action }) {
                mappings[idx].keyCode = code
                mappings[idx].keyLabel = label ?? "Key \(code)"
            }
            isAssigning = false
            assigningAction = nil
            return
        }

        if let mapping = mappings.first(where: { $0.keyCode == code }), mapping.isAssigned {
            onAction?(mapping.action)
        }
    }

    /// SwiftUI `.onKeyPress` bridge for when GCKeyboard is unavailable.
    func handleSwiftUIKey(_ key: String) {
        let normalized = key.lowercased()
        let code: UInt32?
        let label: String
        switch normalized {
        case " ":
            code = 0x2C; label = "Space"
        case "a":
            code = 0x04; label = "A"
        case "r":
            code = 0x15; label = "R"
        case "z":
            code = 0x1D; label = "Z"
        case "o":
            code = 0x12; label = "O"
        case "\u{1B}", "escape":
            code = 0x29; label = "Esc"
        case "leftArrow", "":
            code = 0x50; label = "←"
        case "rightArrow", "":
            code = 0x4F; label = "→"
        default:
            // Hash string into a synthetic code space for custom keys
            code = UInt32(normalized.unicodeScalars.first?.value ?? 0) &+ 0x1000
            label = key.uppercased()
        }
        if let code {
            handleKey(code: code, label: label)
        }
    }
}
