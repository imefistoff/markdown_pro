import Foundation

public enum GitHubError: Error, CustomStringConvertible {
    case http(Int, String)
    case malformed(String)
    case unauthorized

    public var description: String {
        switch self {
        case .http(let c, let m): return "GitHub HTTP \(c): \(m)"
        case .malformed(let m): return "GitHub malformed response: \(m)"
        case .unauthorized: return "GitHub token invalid or lacks access"
        }
    }
}

/// Minimal synchronous GitHub REST client over the Contents API. Synchronous so
/// it fits the app's main-actor `syncNow()`; it blocks on URLSession via a
/// semaphore. `session` is injectable for tests.
public struct GitHubAPI {
    private let owner: String
    private let repo: String
    private let token: String
    private let session: URLSession
    private let base = "https://api.github.com"

    public init(owner: String, repo: String, token: String, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.token = token
        self.session = session
    }

    private func send(_ method: String, _ urlString: String, accept: String = "application/vnd.github+json",
                      body: Data? = nil) throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw GitHubError.malformed("bad url \(urlString)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        var out: (Data, Int)?
        var failure: Error?
        session.dataTask(with: req) { data, resp, err in
            if let err { failure = err }
            else if let http = resp as? HTTPURLResponse { out = (data ?? Data(), http.statusCode) }
            else { failure = GitHubError.malformed("no response") }
            sem.signal()
        }.resume()
        sem.wait()
        if let failure { throw failure }
        guard let out else { throw GitHubError.malformed("no response") }
        if out.1 == 401 || out.1 == 403 { throw GitHubError.unauthorized }
        return out
    }

    private func contentsURL(_ path: String) -> String {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "\(base)/repos/\(owner)/\(repo)/contents/\(escaped)"
    }

    /// The decoded bytes + blob sha for a file, or nil on 404.
    public func getContent(_ path: String) throws -> (data: Data, sha: String)? {
        let (data, code) = try send("GET", contentsURL(path))
        if code == 404 { return nil }
        guard code == 200 else { throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = obj["content"] as? String,
              let sha = obj["sha"] as? String,
              let decoded = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")) else {
            throw GitHubError.malformed("contents \(path)")
        }
        return (decoded, sha)
    }

    /// Create or update a file. Pass `sha` to update an existing file, nil to create.
    public func putContent(_ path: String, data: Data, message: String, sha: String?) throws {
        var payload: [String: Any] = ["message": message, "content": data.base64EncodedString()]
        if let sha { payload["sha"] = sha }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (respData, code) = try send("PUT", contentsURL(path), body: body)
        guard code == 200 || code == 201 else {
            throw GitHubError.http(code, String(data: respData, encoding: .utf8) ?? "")
        }
    }

    /// Names of the immediate children of a directory, or [] if it doesn't exist.
    public func listDir(_ path: String) throws -> [String] {
        let (data, code) = try send("GET", contentsURL(path))
        if code == 404 { return [] }
        guard code == 200 else { throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.malformed("listDir \(path)")
        }
        return arr.compactMap { $0["name"] as? String }
    }

    /// Raw bytes for a file, or nil on 404.
    public func getRaw(_ path: String) throws -> Data? {
        let (data, code) = try send("GET", contentsURL(path), accept: "application/vnd.github.raw")
        if code == 404 { return nil }
        guard code == 200 else { throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    /// True if the repo is reachable with this token.
    public func getRepoExists() throws -> Bool {
        let (_, code) = try send("GET", "\(base)/repos/\(owner)/\(repo)")
        if code == 404 { return false }
        guard code == 200 else { throw GitHubError.http(code, "repo check") }
        return true
    }
}
