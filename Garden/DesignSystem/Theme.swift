import SwiftUI

/// Visual locks (DESIGN §17): one accent (Garden green, from the AccentColor asset),
/// cool system greys, cards at 20pt continuous corners, chips and actions as capsules.
enum Theme {
    static let cardRadius: CGFloat = 20
    static let rowIconSize: CGFloat = 36
    static let spacing: CGFloat = 16
}

extension CategoryTint {
    var color: Color {
        switch self {
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .brown: .brown
        case .gray: .gray
        }
    }
}

// MARK: - Card surface

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

extension Color {
    /// Screen background behind cards — the grouped system colour, so cards read as raised in both themes.
    static var groupedBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

// MARK: - Symbol badge

struct SymbolBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = Theme.rowIconSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: .circle)
            .accessibilityHidden(true)
    }
}

// MARK: - Amount

/// Expenses read as plain amounts in the label colour; income carries a "+" (DESIGN §17).
struct AmountText: View {
    let movement: Movement

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(style)
            .strikethrough(movement.status == .tombstoned)
            // Amounts never wrap; the title beside them truncates instead.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var text: String {
        let amount = movement.amount
        switch movement.kind {
        case .income, .extraIncome, .refund: return "+" + amount.magnitude.formatted
        default: return amount.magnitude.formatted
        }
    }

    private var style: AnyShapeStyle {
        switch movement.kind {
        case .income, .extraIncome, .refund: AnyShapeStyle(.green)
        case .transfer: AnyShapeStyle(.secondary)
        case .expense: AnyShapeStyle(.primary)
        }
    }
}

// MARK: - Progress with pace tick

struct BudgetBar: View {
    let fraction: Double
    /// Where the cycle is now (0...1); drawn as a tick so "ahead of pace" is visible.
    var pace: Double?
    /// The budget's own data colour; falls back to the app accent.
    var tint: Color?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fillStyle)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                if let pace {
                    Capsule()
                        .fill(.primary.opacity(0.35))
                        .frame(width: 2, height: height + 6)
                        .offset(x: proxy.size.width * min(max(pace, 0), 1) - 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Usado")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }

    private var fillStyle: AnyShapeStyle {
        if fraction > 1 { return AnyShapeStyle(.red) }
        if let pace, fraction > pace + 0.1 { return AnyShapeStyle(.orange) }
        if let tint { return AnyShapeStyle(tint.gradient) }
        return AnyShapeStyle(.tint)
    }
}

// MARK: - Day header

extension Date {
    /// "Hoje", "Ontem", "sex., 3 de out."
    var dayHeader: String {
        let calendar = Calendar.brazil
        if calendar.isDateInToday(self) { return String(localized: "Hoje") }
        if calendar.isDateInYesterday(self) { return String(localized: "Ontem") }
        return formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Money.brazil))
    }
}
