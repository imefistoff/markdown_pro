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
