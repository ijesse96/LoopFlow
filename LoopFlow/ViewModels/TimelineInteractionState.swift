import Foundation
import CoreGraphics

@MainActor
final class TimelineInteractionState: ObservableObject {
    @Published var selectedClipId: UUID?
    @Published var showEditSheet = false
    @Published var scrollOffsetX: CGFloat = 0
    @Published var pinchAnchorBeats: Double?
    /// Playhead position (beats) remembered when opening the clip editor for Split.
    @Published var splitAnchorBeats: Double?
    /// Bumped to ask the arrange view to scroll the playhead on-screen (nudge/scrub).
    @Published private(set) var playheadScrollToken: UInt = 0

    func requestScrollPlayheadIntoView() {
        playheadScrollToken &+= 1
    }

    /// Minimum / maximum pixels per bar for zoom.
    static let minPixelsPerBar: CGFloat = 16
    static let maxPixelsPerBar: CGFloat = 240

    func selectClip(_ id: UUID?, presentSheet: Bool = false, splitAnchorBeats: Double? = nil) {
        selectedClipId = id
        showEditSheet = presentSheet && id != nil
        if presentSheet, id != nil {
            self.splitAnchorBeats = splitAnchorBeats
        }
        if id == nil {
            self.splitAnchorBeats = nil
        }
    }

    func clearClipSelection() {
        selectedClipId = nil
        showEditSheet = false
        splitAnchorBeats = nil
    }
}
