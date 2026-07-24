import SwiftUI

enum ArrangeMetrics {
    static let headerWidth: CGFloat = 132
    /// Ruler with loop band + playhead cap.
    static let rulerHeightLoopOn: CGFloat = 36
    /// Compact ruler when loop chrome is hidden.
    static let rulerHeightLoopOff: CGFloat = 22
    static let playheadCapHeight: CGFloat = 14
    static let laneHeight: CGFloat = 88
    /// Scrub gain: finger travel maps to less timeline travel (less sensitive).
    static let playheadScrubGain: CGFloat = 0.45

    static func rulerHeight(loopEnabled: Bool) -> CGFloat {
        loopEnabled ? rulerHeightLoopOn : rulerHeightLoopOff
    }

    static func loopBandHeight(loopEnabled: Bool) -> CGFloat {
        guard loopEnabled else { return 0 }
        return rulerHeightLoopOn - playheadCapHeight
    }
}
