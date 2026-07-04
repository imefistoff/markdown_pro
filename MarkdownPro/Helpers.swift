import SwiftUI
import MarkdownProCore

extension Color {
    /// Parses "#RRGGBB" (with or without the #).
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension TaskStatus {
    var iconName: String {
        switch self {
        case .backlog: return "circle.dashed"
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .canceled: return "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .backlog: return .secondary
        case .todo: return .secondary
        case .inProgress: return .orange
        case .done: return .green
        case .canceled: return .secondary
        }
    }
}

extension TaskPriority {
    var iconName: String {
        switch self {
        case .urgent: return "exclamationmark.triangle.fill"
        case .high: return "chart.bar.fill"
        case .medium: return "chart.bar.fill"
        case .low: return "chart.bar"
        case .none: return "minus"
        }
    }

    var color: Color {
        switch self {
        case .urgent: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .none: return .secondary
        }
    }
}

struct LabelChip: View {
    let label: MarkdownProCore.Label

    var body: some View {
        Text(label.name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: label.color).opacity(0.18))
            .foregroundStyle(Color(hex: label.color))
            .clipShape(Capsule())
    }
}

extension TaskAttention {
    var iconName: String {
        switch self {
        case .needsReview: return "eye"
        case .changesRequested: return "arrow.uturn.left"
        case .readyToExecute: return "play.circle"
        case .executing: return "gearshape.2"
        }
    }

    var color: Color {
        switch self {
        case .needsReview: return .orange
        case .changesRequested: return .yellow
        case .readyToExecute: return .green
        case .executing: return .blue
        }
    }
}

extension DocumentState {
    var color: Color {
        switch self {
        case .needsReview: return .orange
        case .changesRequested: return .yellow
        case .approved: return .green
        case .rejected: return .red
        case .superseded: return .gray
        }
    }
}

/// Small colored capsule used for attention / review-state chips.
struct AttentionChip: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        SwiftUI.Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

extension Date {
    var shortFormatted: String {
        formatted(date: .abbreviated, time: .omitted)
    }

    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
