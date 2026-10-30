import SwiftUI

// Design system — promotes the generated DADTokens palette/scale into reusable,
// accessibility-first SwiftUI primitives. Every surface sets a background WITH its
// foreground so light/dark both read; color is never the only signal.

public extension Color {
    /// Resolve a DAD design token by name. Falls back to `.primary` for an unknown
    /// token rather than a literal palette value, so a typo is visible, not silently wrong.
    static func dad(_ token: String) -> Color {
        guard let hex = DADTokens.color[token] else { return .primary }
        return Color(dadHex: hex)
    }

    init(dadHex hex: String) {
        // Supports #rgb, #rrggbb and rgba(r,g,b,a); anything else resolves to .primary so it is visible.
        if let rgb = Color.parseHex(hex) {
            self = rgb
        } else if hex.hasPrefix("rgba("), let parsed = Color.parseRGBA(hex) {
            self = parsed
        } else {
            self = .primary
        }
    }

    /// `#rgb` shorthand expands each digit (e.g. the `card` token `#fff`).
    static func parseHex(_ hex: String) -> Color? {
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    static func parseRGBA(_ hex: String) -> Color? {
        let inner = hex.dropFirst(5).dropLast()
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let r = Double(parts[0]), let g = Double(parts[1]),
              let b = Double(parts[2]), let a = Double(parts[3]) else { return nil }
        return Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

public extension CGFloat {
    static func dadSpace(_ step: String) -> CGFloat { CGFloat(DADTokens.space[step] ?? 0) }
    static func dadRadius(_ name: String) -> CGFloat { CGFloat(DADTokens.radius[name] ?? 0) }
}

/// Theme-aware page background (paper in light, ink-deep in dark) paired with its text color.
public struct DADBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.dad(scheme == .dark ? "paper" : "ink"))
            .background(Color.dad(scheme == .dark ? "ink-deep" : "paper").ignoresSafeArea())
    }
}

public extension View {
    func dadBackground() -> some View { modifier(DADBackground()) }
}

/// Primary call-to-action. 44pt minimum target, Dynamic Type, brand-on-wash with readable contrast.
public struct DADButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary }
    private let kind: Kind
    @Environment(\.colorScheme) private var scheme
    public init(_ kind: Kind = .primary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        let background: Color
        let foreground: Color
        switch kind {
        case .primary:
            background = .dad("brand")
            foreground = .dad("paper")
        case .secondary:
            background = .dad(scheme == .dark ? "ink" : "card")
            foreground = .dad(scheme == .dark ? "paper" : "ink")
        }
        return configuration.label
            .font(.body.weight(.semibold))
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, .dadSpace("4"))
            .background(background.opacity(configuration.isPressed ? 0.82 : 1))
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: .dadRadius("pill"), style: .continuous))
            .overlay {
                // Secondary buttons sit on same-coloured cards; the outline keeps them visible.
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: .dadRadius("pill"), style: .continuous)
                        .strokeBorder(Color.dad(scheme == .dark ? "ghost-line-dark" : "ghost-line"), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
    }
}

/// Grouped content surface — card background + text color pair, themed.
public struct DADCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(.dadSpace("5"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dad(scheme == .dark ? "ink" : "card"))
            .foregroundStyle(Color.dad(scheme == .dark ? "paper" : "ink"))
            .clipShape(RoundedRectangle(cornerRadius: .dadRadius("card"), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: .dadRadius("card"), style: .continuous)
                    .strokeBorder(Color.dad(scheme == .dark ? "dkline" : "line"), lineWidth: 1)
            )
    }
}

/// 30-day streak bar. Each filled day carries a shape fill AND is labeled for VoiceOver —
/// color is never the only signal (PRD §10 / a11y bar requirement).
public struct DADStreakBar: View {
    private let filled: Int
    private let total: Int
    public init(filled: Int, total: Int = 30) {
        self.total = max(total, 1)
        self.filled = min(max(filled, 0), self.total)
    }
    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < filled ? Color.dad("brand") : Color.dad("line"))
                    .frame(height: 10)
                    .overlay(
                        // Shape cue in addition to color for the filled segments.
                        index < filled
                            ? RoundedRectangle(cornerRadius: 2).strokeBorder(Color.dad("brand-ink"), lineWidth: 0.5)
                            : nil
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streak")
        .accessibilityValue("\(filled) of \(total) days")
    }
}
