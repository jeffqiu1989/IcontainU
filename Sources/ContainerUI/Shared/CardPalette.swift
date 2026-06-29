import SwiftUI

/// The app's semantic color system.
///
/// Color encodes *meaning* — what kind of thing this is — not identity. A network
/// is always blue, a volume always orange, wherever it appears (sidebar icon,
/// card chip, badge). Identity is carried by text, not hue. Cards themselves stay
/// neutral so these semantic colors read clearly against them.
enum Palette {
    // MARK: Domains (sidebar + cards share these)

    static let containers = Color.teal
    static let compose = Color.green
    static let machines = Color.brown
    static let images = Color.purple
    static let volumes = Color.orange
    static let networks = Color.blue
    static let registries = Color.pink
    static let system = Color.gray

    // MARK: Data types inside a container card

    static let network = Color.blue
    static let port = Color.indigo
    static let mount = Color.orange

    // MARK: Neutral card surface

    /// Hairline border around content cards — neutral, not tinted.
    static let cardBorder = Color(nsColor: .separatorColor)
    /// Border of a selected card / its accent bar.
    static let selection = Color.accentColor
}

/// A semantic accent color plus the soft tints derived from it (chip fills, tag
/// backgrounds, borders). Construct it from a domain color via `.init(color:)`,
/// not from a random seed — color carries meaning, not identity.
struct CardPalette {
    let base: Color
    /// When true the card draws a soft border in its own hue rather than a neutral
    /// gray one. Identity-colored cards (seeded) opt in; semantic cards stay gray.
    private let tintedBorder: Bool

    init(color: Color) {
        self.base = color
        self.tintedBorder = false
    }

    /// A curated set of pleasant, well-separated hues used by seeded cards.
    private static let hues: [Color] = [
        .blue, .teal, .green, .orange, .pink, .purple, .indigo, .red, .mint, .cyan,
    ]

    /// Derives a stable, distinct accent color from an identifier so each card
    /// gets its own color across refreshes (FNV-1a hash → curated hue).
    init(seed: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let index = Int(hash % UInt64(Self.hues.count))
        self.base = Self.hues[index]
        self.tintedBorder = true
    }

    /// Border for content cards: a soft hue for seeded cards, neutral gray for
    /// semantic ones (tinting competes with the semantic chips inside).
    var border: Color { tintedBorder ? base.opacity(0.5) : Palette.cardBorder }

    /// Very light background wash (used by domains that still want a faint tint).
    var background: AnyShapeStyle {
        AnyShapeStyle(base.opacity(0.08).gradient)
    }

    /// Soft filled chip used for tags.
    var tagFill: Color { base.opacity(0.18) }
    var tagText: Color { base }

    /// The semantic accent color itself.
    var accent: Color { base }
}
