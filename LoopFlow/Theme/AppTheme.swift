import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surface = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let surfaceElevated = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let border = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.55)
    static let accent = Color(red: 1.0, green: 0.35, blue: 0.25)
    static let record = Color(red: 0.92, green: 0.18, blue: 0.22)
    static let regionHighlight = Color(red: 0.75, green: 0.12, blue: 0.18).opacity(0.45)
    static let waveform = Color(red: 0.95, green: 0.45, blue: 0.28)
    static let gridLine = Color.white.opacity(0.08)
    static let beatLine = Color.white.opacity(0.04)
    static let playhead = Color.white
    static let transport = Color.white.opacity(0.9)
}
