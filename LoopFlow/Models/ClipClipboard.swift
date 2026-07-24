import Foundation

struct ClipClipboard: Equatable {
    var clip: AudioClip
    /// Absolute timeline start in beats when copied (for reference).
    var originalTimelineStartBeats: Double
}
