import Foundation

/// Calls the FunAsia admin backend (`/api/admin/*`) with the signed-in
/// admin's Firebase ID token.
///
/// The base URL is a setting rather than a constant, because the backend runs
/// on localhost during development and moves to funasia.net once the
/// port-admin-api branch is deployed. Going live is then a settings change,
/// not a rebuild.
enum AdminAPI {
    static let baseKey = "adminAPIBase"
    static let production = "https://www.funasia.net"
    static let localDev = "http://localhost:3001"

    static var baseString: String {
        UserDefaults.standard.string(forKey: baseKey) ?? production
    }
    static var base: URL? { URL(string: baseString) }

    enum Failure: LocalizedError {
        case notConfigured
        case unauthorized
        case offline
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No backend address is set."
            case .unauthorized:  return "Not authorised — this needs a superadmin account."
            case .offline:
                return "The admin backend is not reachable at \(AdminAPI.baseString). "
                     + "Start the local server, or switch the address in Settings."
            case .server(let c, let m): return m.isEmpty ? "Server error \(c)" : m
            }
        }
    }

    @discardableResult
    static func call(_ method: String, _ path: String, body: [String: Any]? = nil,
                     session: AdminSession, retried: Bool = false) async throws -> [String: Any] {
        guard let base else { throw Failure.notConfigured }
        guard let token = await session.validToken() else { throw Failure.unauthorized }

        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw Failure.offline }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        // 404 on an admin path means the routes are not deployed, which is a
        // different problem from a missing record and deserves its own message.
        if code == 404, path.hasPrefix("api/admin"), json?["error"] == nil {
            throw Failure.offline
        }
        if code == 401 {
            // one refresh-and-retry, then give up
            if !retried { return try await call(method, path, body: body, session: session, retried: true) }
            throw Failure.unauthorized
        }
        guard (200..<300).contains(code) else {
            throw Failure.server(code, json?["error"] as? String ?? "")
        }
        return json ?? [:]
    }

    /// Is a backend answering at all? 401 counts as reachable — it means the
    /// route exists and simply refused us.
    static func probe() async -> Bool {
        guard let base, let url = URL(string: "api/admin/bigfan/stations", relativeTo: base) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code == 401 || (200..<300).contains(code)
    }
}

// MARK: - BigFan

extension AdminAPI {
    static func bigfanList(_ key: String, session: AdminSession) async throws -> [[String: Any]] {
        try await call("GET", "api/admin/bigfan/\(key)", session: session)["items"] as? [[String: Any]] ?? []
    }
    static func bigfanCreate(_ key: String, _ fields: [String: Any], session: AdminSession) async throws -> String {
        try await call("POST", "api/admin/bigfan/\(key)", body: fields, session: session)["id"] as? String ?? ""
    }
    static func bigfanUpdate(_ key: String, id: String, _ fields: [String: Any], session: AdminSession) async throws {
        try await call("PATCH", "api/admin/bigfan/\(key)/\(id)", body: fields, session: session)
    }
    static func bigfanDelete(_ key: String, id: String, session: AdminSession) async throws {
        try await call("DELETE", "api/admin/bigfan/\(key)/\(id)", session: session)
    }
    static func pickWinner(questionId: String, session: AdminSession) async throws -> [String: Any] {
        try await call("POST", "api/admin/bigfan/trivia-questions/\(questionId)/pick-winner", session: session)
    }
}
