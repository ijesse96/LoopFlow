import Foundation
import AVFoundation

/// Protocol for future AUv3 / built-in DSP inserts. V1 ships empty slots only.
protocol EffectNode: AnyObject {
    var id: UUID { get }
    var name: String { get }
    var bypass: Bool { get set }
    var parameters: [String: Double] { get set }

    func makeAVAudioNode() -> AVAudioNode?
    func attach(to engine: AVAudioEngine)
    func detach(from engine: AVAudioEngine)
}

final class EmptyEffectSlot: EffectNode {
    let id: UUID
    let name: String = "Empty"
    var bypass: Bool = true
    var parameters: [String: Double] = [:]

    init(id: UUID = UUID()) {
        self.id = id
    }

    func makeAVAudioNode() -> AVAudioNode? { nil }
    func attach(to engine: AVAudioEngine) {}
    func detach(from engine: AVAudioEngine) {}
}

struct EffectSlot {
    var state: EffectSlotState
    var node: EffectNode

    static func empty(count: Int = 3) -> [EffectSlot] {
        (0..<count).map { _ in
            let state = EffectSlotState()
            return EffectSlot(state: state, node: EmptyEffectSlot(id: state.id))
        }
    }
}
