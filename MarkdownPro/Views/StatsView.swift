import SwiftUI
import Charts
import MarkdownProCore

struct StatsView: View {
    @EnvironmentObject private var store: Store
    @State private var completions: [Repository.DayCount] = []

    private var doneCount: Int { store.tasks.filter { $0.status == .done }.count }
    private var inProgressCount: Int { store.tasks.filter { $0.status == .inProgress }.count }
    // "Open" = not-yet-started work only, so the tiles don't overlap with
    // In Progress / Done (Overdue stays an independent overlay lens).
    private var openCount: Int {
        store.tasks.filter { $0.status == .backlog || $0.status == .todo }.count
    }
    private var overdueCount: Int { store.tasks.filter(\.isOverdue).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Progress")
                    .font(.largeTitle.bold())

                // Stat tiles
                HStack(spacing: 12) {
                    statTile("Open", value: openCount, color: .blue, icon: "tray.full")
                    statTile("In Progress", value: inProgressCount, color: .orange, icon: "circle.lefthalf.filled")
                    statTile("Done", value: doneCount, color: .green, icon: "checkmark.circle.fill")
                    statTile("Overdue", value: overdueCount, color: overdueCount > 0 ? .red : .secondary, icon: "calendar.badge.exclamationmark")
                }

                // Completions over the last 14 days
                VStack(alignment: .leading, spacing: 8) {
                    Text("Completed · last 14 days")
                        .font(.headline)
                    if completions.isEmpty {
                        Text("Nothing completed yet — move a task to Done and it shows up here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        Chart(completions) { day in
                            BarMark(
                                x: .value("Day", String(day.day.suffix(5))),
                                y: .value("Done", day.count)
                            )
                            .foregroundStyle(Color.green.gradient)
                            .cornerRadius(3)
                        }
                        .frame(height: 160)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))

                // Per-project progress
                VStack(alignment: .leading, spacing: 10) {
                    Text("Projects")
                        .font(.headline)
                    if store.projects.isEmpty {
                        Text("No projects yet. Create one from the sidebar (+).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.projects) { project in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: project.color))
                                .frame(width: 9, height: 9)
                            Text(project.name)
                                .frame(width: 180, alignment: .leading)
                                .lineLimit(1)
                            ProgressView(value: project.progress)
                                .tint(Color(hex: project.color))
                            Text("\(project.doneCount)/\(project.taskCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .onAppear { completions = store.completionsByDay() }
        .onChange(of: store.tasks) { _, _ in
            completions = store.completionsByDay()
        }
    }

    private func statTile(_ title: String, value: Int, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(value)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }
}
