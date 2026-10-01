import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case unauthorized
    case needsSignIn
    case http(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add the server address and access key in Settings."
        case .unauthorized:  return "The server rejected the access key. Check it in Settings."
        case .needsSignIn:   return "Sign in with your funasia.net account to continue."
        case .http(let c, let m):
            return "The server returned an error (\(c))\(m.isEmpty ? "" : ": \(m)")"
        case .transport(let m): return m
        }
    }
}

struct APIClient {
    var baseURL: String
    /// Optional. People are authenticated by Cloudflare Access, which sets a
    /// cookie the shared URLSession store carries. The key only exists so
    /// scripts can call the Worker directly, and the app never asks for one.
    var token: String = ""

    private var session: URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = []) async throws -> T {
        guard !baseURL.isEmpty,
              var comps = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces))
        else { throw APIError.notConfigured }

        comps.path = path
        if !items.isEmpty { comps.queryItems = items }
        guard let url = comps.url else { throw APIError.notConfigured }

        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = true
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw APIError.transport(error.localizedDescription) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // Cloudflare Access answers an unauthenticated request with its own
        // login page rather than JSON, so an HTML body means "sign in", not
        // "bad token".
        let ctype = (resp as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let host = (resp as? HTTPURLResponse)?.url?.host ?? ""
        if ctype.contains("text/html") || host.contains("cloudflareaccess.com") {
            throw APIError.needsSignIn
        }
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error"] as? String } ?? ""
            throw APIError.http(code, msg)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.transport("Could not read the response: \(error.localizedDescription)") }
    }

    func stations() async throws -> StationsResponse { try await get("/stations") }

    func coverage(date: String) async throws -> CoverageResponse {
        try await get("/coverage", [.init(name: "date", value: date)])
    }

    func stats(days: Int, station: String? = nil) async throws -> StatsResponse {
        var q = [URLQueryItem(name: "days", value: String(days))]
        if let s = station { q.append(.init(name: "station", value: s)) }
        return try await get("/stats", q)
    }

    func recordings(date: String, station: String?) async throws -> RecordingsResponse {
        var q = [URLQueryItem(name: "date", value: date)]
        if let s = station { q.append(.init(name: "station", value: s)) }
        return try await get("/recordings", q)
    }

    /// AVPlayer shares the app's cookie store, so an Access session is carried
    /// automatically. The key is appended only when one is configured.
    func playbackURL(for rec: Recording) -> URL? {
        guard var c = URLComponents(string: rec.audioURL) else { return nil }
        if !token.isEmpty { c.queryItems = [URLQueryItem(name: "token", value: token)] }
        return c.url
    }

    func me() async throws -> Me { try await get("/me") }

    /// Streams one recording to a local file.
    func download(_ rec: Recording, to destination: URL) async throws {
        guard let url = playbackURL(for: rec) else { throw APIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = true
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            try? FileManager.default.removeItem(at: tmp)
            if code == 401 { throw APIError.needsSignIn }
            throw APIError.http(code, "")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }
}
