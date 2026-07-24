import Foundation

enum MusicalKey: String, Codable, CaseIterable, Identifiable {
    case c = "C"
    case cSharp = "C#"
    case d = "D"
    case dSharp = "D#"
    case e = "E"
    case f = "F"
    case fSharp = "F#"
    case g = "G"
    case gSharp = "G#"
    case a = "A"
    case aSharp = "A#"
    case b = "B"
    case cMinor = "Cm"
    case cSharpMinor = "C#m"
    case dMinor = "Dm"
    case dSharpMinor = "D#m"
    case eMinor = "Em"
    case fMinor = "Fm"
    case fSharpMinor = "F#m"
    case gMinor = "Gm"
    case gSharpMinor = "G#m"
    case aMinor = "Am"
    case aSharpMinor = "A#m"
    case bMinor = "Bm"

    var id: String { rawValue }
}
