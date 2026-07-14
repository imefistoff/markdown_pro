import XCTest
@testable import MarkdownProCore

final class ExportBundleTests: XCTestCase {

    func testBundleRoundTripsThroughJSON() throws {
        let bundle = ExportBundle(
            formatVersion: ExportBundle.currentFormatVersion,
            exportedAt: "2026-07-14T10:00:00.000Z",
            projects: [
                ExportedProject(
                    name: "MarkdownPro",
                    color: "#5E6AD2",
                    archived: false,
                    createdAt: "2026-06-01T09:00:00.000Z",
                    updatedAt: "2026-07-14T08:00:00.000Z",
                    documents: [
                        ExportedDocument(title: "Roadmap", originalPath: "/tmp/roadmap.md", file: "documents/0001-roadmap.md")
                    ],
                    tasks: [
                        ExportedTask(
                            title: "Add export",
                            details: "…",
                            status: "in_progress",
                            priority: "high",
                            dueDate: "2026-07-20",
                            sortOrder: 3,
                            createdAt: "2026-07-01T11:00:00.000Z",
                            updatedAt: "2026-07-13T16:00:00.000Z",
                            labels: [ExportedLabel(name: "feature", color: "#8B5CF6")],
                            subtasks: [ExportedSubtask(title: "Zip writer", done: true, sortOrder: 1)],
                            activity: [ExportedActivity(actor: "claude", kind: "status",
                                                        message: "moved from Todo to In Progress",
                                                        createdAt: "2026-07-02T12:00:00.000Z")],
                            documents: [ExportedDocument(title: "Spec", originalPath: "/tmp/spec.md", file: nil)]
                        )
                    ]
                )
            ]
        )

        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(ExportBundle.self, from: data)

        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.projects.count, 1)
        let project = try XCTUnwrap(decoded.projects.first)
        XCTAssertEqual(project.name, "MarkdownPro")
        XCTAssertEqual(project.documents.first?.file, "documents/0001-roadmap.md")

        let task = try XCTUnwrap(project.tasks.first)
        XCTAssertEqual(task.status, "in_progress")
        XCTAssertEqual(task.dueDate, "2026-07-20")
        XCTAssertEqual(task.labels.first?.name, "feature")
        XCTAssertEqual(task.subtasks.first?.done, true)
        XCTAssertEqual(task.activity.first?.actor, "claude")
        XCTAssertNil(task.documents.first?.file, "a missing file must survive as null")
    }
}
