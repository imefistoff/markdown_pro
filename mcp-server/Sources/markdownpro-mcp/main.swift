import Foundation

do {
    let server = try MCPServer()
    server.run()
} catch {
    FileHandle.standardError.write(Data("[markdownpro-mcp] fatal: \(error)\n".utf8))
    exit(1)
}
