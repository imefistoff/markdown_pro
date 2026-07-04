import XCTest
@testable import MarkdownProCore

/// Review-loop data layer: proposals, rounds, attention, annotations, verdicts.
/// Verdict/annotation tests arrive in later tasks; this file starts with
/// submit/attention/decode coverage and grows.
final class ReviewTests: XCTestCase {
    private var tempPath = ""
    private var repo: Repository!
    private var projectId: Int64 = 0
    private var taskId: Int64 = 0

    override func setUpWithError() throws {
        tempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mdpro-review-\(UUID().uuidString).sqlite")
        repo = Repository(db: try Database.open(path: tempPath))
        projectId = try repo.createProject(name: "P")
        taskId = try repo.createTask(projectId: projectId, title: "T", status: .inProgress)
    }

    override func tearDownWithError() throws {
        repo = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempPath + suffix)
        }
    }

    // submit_for_review: creates a needs_review proposal and flags the task
    func testSubmitForReviewCreatesProposalAndFlagsTask() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/proposal.md", title: "Fix crash")
        let doc = try repo.document(id: docId)!
        XCTAssertEqual(doc.kind, .proposal)
        XCTAssertEqual(doc.state, .needsReview)
        XCTAssertEqual(doc.round, 1)
        XCTAssertEqual(doc.taskId, taskId)
        XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .needsReview)
        XCTAssertTrue(try repo.getTask(id: taskId)!.activity
            .contains { $0.actor == "claude" && $0.message.contains("submitted") })
    }

    // Resubmitting the same task+path bumps the round instead of duplicating
    func testResubmitBumpsRound() throws {
        let first = try repo.submitForReview(taskId: taskId, path: "/tmp/proposal.md", title: nil)
        let second = try repo.submitForReview(taskId: taskId, path: "/tmp/proposal.md", title: nil)
        XCTAssertEqual(first, second, "resubmission must reuse the document row")
        XCTAssertEqual(try repo.document(id: first)!.round, 2)
        XCTAssertEqual(try repo.document(id: first)!.state, .needsReview)
    }

    // setAttention flips and clears the flag with attribution
    func testSetAttention() throws {
        try repo.setAttention(taskId: taskId, attention: .executing)
        XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .executing)
        try repo.setAttention(taskId: taskId, attention: nil)
        XCTAssertNil(try repo.getTask(id: taskId)!.task.attention)
    }

    // listTasks(attention:) filters
    func testListTasksAttentionFilter() throws {
        let other = try repo.createTask(projectId: projectId, title: "Other")
        try repo.setAttention(taskId: taskId, attention: .readyToExecute)
        let hits = try repo.listTasks(attention: .readyToExecute).map(\.id)
        XCTAssertEqual(hits, [taskId])
        XCTAssertFalse(hits.contains(other))
    }

    // attach_document kind lands in the row; default stays note
    func testAttachDocumentKind() throws {
        let wiki = try repo.attachDocument(taskId: nil, projectId: projectId,
                                           path: "/tmp/wiki.md", title: "Wiki", kind: .wiki)
        XCTAssertEqual(try repo.document(id: wiki)!.kind, .wiki)
        let plain = try repo.attachDocument(taskId: taskId, projectId: nil,
                                            path: "/tmp/n.md", title: nil)
        XCTAssertEqual(try repo.document(id: plain)!.kind, .note)
        XCTAssertNil(try repo.document(id: plain)!.state)
    }

    // Annotation lifecycle: open on the current round, addressed with reply
    func testAnnotationLifecycle() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        let annId = try repo.addAnnotation(documentId: docId, quote: "use SQLite",
                                           prefix: "we should ", suffix: " for this",
                                           comment: "agreed, but WAL mode please")
        var anns = try repo.annotations(documentId: docId)
        XCTAssertEqual(anns.count, 1)
        XCTAssertEqual(anns[0].state, .open)
        XCTAssertEqual(anns[0].round, 1)
        XCTAssertEqual(anns[0].author, "user")

        try repo.updateAnnotation(id: annId, comment: "WAL + busy timeout")
        try repo.resolveAnnotation(id: annId, reply: "done — WAL enabled in SQLite.swift")
        anns = try repo.annotations(documentId: docId)
        XCTAssertEqual(anns[0].state, .addressed)
        XCTAssertEqual(anns[0].comment, "WAL + busy timeout")
        XCTAssertEqual(anns[0].reply, "done — WAL enabled in SQLite.swift")
        XCTAssertNotNil(anns[0].resolvedAt)

        try repo.deleteAnnotation(id: annId)
        XCTAssertTrue(try repo.annotations(documentId: docId).isEmpty)
    }

    // Annotations made after a resubmission carry the new round
    func testAnnotationTracksDocumentRound() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        _ = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md") // round 2
        let annId = try repo.addAnnotation(documentId: docId, quote: "q", comment: "c")
        XCTAssertEqual(try repo.annotations(documentId: docId).first { $0.id == annId }?.round, 2)
    }

    // Approve: doc approved, task ready_to_execute
    func testApproveVerdict() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        try repo.applyVerdict(.approve, documentId: docId)
        XCTAssertEqual(try repo.document(id: docId)!.state, .approved)
        XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .readyToExecute)
        XCTAssertTrue(try repo.getTask(id: taskId)!.activity
            .contains { $0.actor == "user" && $0.kind == "review" && $0.message.contains("approved") })
    }

    // Request changes: doc + attention both changes_requested
    func testRequestChangesVerdict() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        try repo.applyVerdict(.requestChanges, documentId: docId)
        XCTAssertEqual(try repo.document(id: docId)!.state, .changesRequested)
        XCTAssertEqual(try repo.getTask(id: taskId)!.task.attention, .changesRequested)
    }

    // Reject: doc rejected, attention cleared, task back to todo
    func testRejectVerdictMovesTaskToTodo() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md")
        try repo.applyVerdict(.reject, documentId: docId)
        XCTAssertEqual(try repo.document(id: docId)!.state, .rejected)
        let task = try repo.getTask(id: taskId)!.task
        XCTAssertNil(task.attention)
        XCTAssertEqual(task.status, .todo)
        XCTAssertTrue(try repo.getTask(id: taskId)!.activity
            .contains { $0.message == "moved from In Progress to Todo" })
    }

    // Queue: needs_review proposals only, with task/project context
    func testReviewQueueContents() throws {
        let docId = try repo.submitForReview(taskId: taskId, path: "/tmp/p.md", title: "Proposal P")
        _ = try repo.attachDocument(taskId: taskId, projectId: nil, path: "/tmp/n.md", title: "Note")
        var queue = try repo.reviewQueue()
        XCTAssertEqual(queue.map(\.id), [docId])
        XCTAssertEqual(queue[0].taskTitle, "T")
        XCTAssertEqual(queue[0].projectName, "P")
        try repo.applyVerdict(.approve, documentId: docId)
        queue = try repo.reviewQueue()
        XCTAssertTrue(queue.isEmpty, "verdicted docs leave the queue")
    }

    // Verdict on an unknown document fails loudly
    func testVerdictOnMissingDocumentThrows() throws {
        XCTAssertThrowsError(try repo.applyVerdict(.approve, documentId: 999))
    }
}
