import XCTest
@testable import MarkdownProCore

final class SyncAdoptionTests: XCTestCase {

    override func setUp() { super.setUp(); FakeGitHubServer.reset() }

    private func makePair() throws -> (a: TestDatabase, b: TestDatabase, ea: SyncEngine, eb: SyncEngine) {
        let a = try TestDatabase(), b = try TestDatabase()
        return (a, b,
                SyncEngine(repo: a.repo, transport: GitHubTransport(owner: "o", repo: "r", token: "t",
                    deviceId: try a.repo.syncState().deviceId, session: FakeGitHubServer.session())),
                SyncEngine(repo: b.repo, transport: GitHubTransport(owner: "o", repo: "r", token: "t",
                    deviceId: try b.repo.syncState().deviceId, session: FakeGitHubServer.session())))
    }

    func testUnadoptedProjectAppearsInCatalogThenDisappearsAfterAdopt() throws {
        let p = try makePair()
        let projectId = try p.a.repo.createProject(name: "Shared board")
        try p.a.repo.setProjectSynced(id: projectId, synced: true)
        let projectUUID = try p.a.repo.entityUUID(.project, id: projectId)!
        try p.a.repo.createTask(projectId: projectId, title: "a task")
        try p.ea.sync()

        // B has not adopted: nothing materialized, but the catalog offers it.
        try p.eb.sync()
        XCTAssertTrue(try p.b.repo.listProjects(includeArchived: true).allSatisfy { $0.name != "Shared board" })
        let catalog = try p.eb.availableToAdopt()
        XCTAssertEqual(catalog.map(\.uuid), [projectUUID])
        XCTAssertEqual(catalog.first?.name, "Shared board")

        // Adopt, sync: it's now a real project and leaves the catalog.
        try p.b.repo.adoptProject(remoteUUID: projectUUID, name: catalog.first!.name)
        try p.eb.sync()
        XCTAssertTrue(try p.b.repo.listProjects().contains { $0.name == "Shared board" })
        XCTAssertEqual(try p.b.repo.listTasks().map(\.title), ["a task"])
        XCTAssertTrue(try p.eb.availableToAdopt().isEmpty, "an adopted project is no longer offered")
    }
}
