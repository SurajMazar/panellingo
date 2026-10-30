import CoreText
import Foundation

/// Lettering presets built only from fonts that ship with macOS (no font redistribution).
public enum TextStylePresets {
    public static let classic = TextStyle(presetID: "classic", fontFamily: "Comic Sans MS", bold: true)

    public static let manga = TextStyle(presetID: "manga", fontFamily: "Avenir Next Condensed", bold: true,
                                        lineSpacing: 0.95)

    public static let webtoon = TextStyle(presetID: "webtoon", fontFamily: "SF Pro Rounded", bold: true,
                                          lineSpacing: 1.05)

    public static let handwritten = TextStyle(presetID: "handwritten", fontFamily: "Chalkboard SE", bold: false)

    public static let cleanSans = TextStyle(presetID: "clean", fontFamily: "Helvetica Neue", bold: false)

    public static let sfx = TextStyle(presetID: "sfx", fontFamily: "Impact", maxFontSize: 220, bold: false,
                                      uppercase: true, textColor: .black, strokeColor: .white, strokeWidth: 0.18,
                                      padding: 0.02)

    public static let caption = TextStyle(presetID: "caption", fontFamily: "Avenir Next", bold: false,
                                          alignment: .center, lineSpacing: 1.05, padding: 0.08)

    public static let all: [(id: String, name: String, style: TextStyle)] = [
        ("classic", "Classic Comic", classic),
        ("manga", "Manga Dialogue", manga),
        ("webtoon", "Modern Webtoon", webtoon),
        ("handwritten", "Handwritten", handwritten),
        ("clean", "Clean Sans Serif", cleanSans),
        ("sfx", "Bold Sound Effect", sfx),
        ("caption", "Narration Caption", caption),
    ]

    public static func preset(_ id: String) -> TextStyle? { all.first { $0.id == id }?.style }

    /// Style used for a freshly detected region of the given kind.
    public static func style(for kind: RegionKind, projectDefault: TextStyle) -> TextStyle {
        switch kind {
        case .sfx: return sfx
        case .caption: return projectDefault.presetID == "classic" ? caption : projectDefault
        case .artText: var s = projectDefault; s.strokeWidth = 0.12; return s
        default: return projectDefault
        }
    }

    /// Installed font families, for pickers.
    public static func installedFamilies() -> [String] {
        (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
}
