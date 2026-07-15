import Foundation
@testable import MarkdownProCore

/// In-memory model of one GitHub repo, served to `GitHubAPI` via `URLProtocol`.
/// Keyed by repo-relative path (e.g. "ops/devA/1.jsonl", "blobs/<sha>", "devices.json").
final class FakeGitHubServer {
    static var files: [String: Data] = [:]
    static var repoExists = true
    static var lastAuthHeader: String?

    static func reset() {
        files = [:]
        repoExists = true
        lastAuthHeader = nil
    }

    /// A URLSession whose only protocol is the fake.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGitHubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class FakeGitHubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.github.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        FakeGitHubServer.lastAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        guard let url = request.url else { return finish(400, Data()) }
        let path = url.path                       // e.g. /repos/o/r/contents/ops/devA/1.jsonl
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let method = request.httpMethod ?? "GET"

        // GET /repos/<o>/<r>  → repo existence
        if let range = path.range(of: "/repos/"), path[range.upperBound...].split(separator: "/").count == 2 {
            return FakeGitHubServer.repoExists ? finishJSON(200, ["full_name": "o/r"]) : finish(404, Data())
        }
        // Contents API: /repos/<o>/<r>/contents/<repoPath>
        if let r = path.range(of: "/contents/") {
            let repoPath = String(path[r.upperBound...]).removingPercentEncoding ?? String(path[r.upperBound...])
            let acceptRaw = request.value(forHTTPHeaderField: "Accept")?.contains("raw") == true
            switch method {
            case "GET" where acceptRaw:
                if let data = FakeGitHubServer.files[repoPath] { return finish(200, data) }
                return finish(404, Data())
            case "GET":
                // A directory listing if any file has this prefix and no exact file.
                if FakeGitHubServer.files[repoPath] == nil {
                    let children = FakeGitHubServer.files.keys.filter { $0.hasPrefix(repoPath + "/") }
                        .map { String($0.dropFirst(repoPath.count + 1)).split(separator: "/").first.map(String.init) ?? "" }
                    if children.isEmpty { return finish(404, Data()) }
                    let arr = Array(Set(children)).map { ["name": $0, "path": repoPath + "/" + $0] }
                    return finishJSON(200, arr)
                }
                let data = FakeGitHubServer.files[repoPath]!
                return finishJSON(200, ["content": data.base64EncodedString(), "sha": sha(repoPath)])
            case "PUT":
                let body = (try? JSONSerialization.jsonObject(with: request.httpBodyData())) as? [String: Any]
                let b64 = body?["content"] as? String ?? ""
                FakeGitHubServer.files[repoPath] = Data(base64Encoded: b64) ?? Data()
                return finishJSON(201, ["content": ["path": repoPath]])
            default:
                return finish(405, Data())
            }
        }
        finish(404, Data())
    }

    private func sha(_ path: String) -> String { String(path.hashValue, radix: 16) }

    private func finish(_ code: Int, _ data: Data) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func finishJSON(_ code: Int, _ obj: Any) {
        finish(code, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
    }
}

private extension URLRequest {
    /// URLProtocol strips httpBody for streamed bodies; read from the stream if needed.
    func httpBodyData() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}
