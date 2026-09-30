import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case unauthorized
    case http(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:      return "Set the server URL and API token in Settings."
        case .unauthorized:       return "The API rejected the token (401). Check it in Settings."
        case .http(let c, let m): return "Server returned \(c)\(m.isEmpty ? "" : ": \(m)")"
        case .transport(let m):   return m
        }
    }
}

struct APIClient {
    var baseURL: String
    var token: String

    private var session: URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = []) async throws -> T {
        guard !baseURL.isEmpty, !token.isEmpty,
              var comps = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces))
        else { throw APIError.notConfigured }

        comps.path = path
        if !items.isEmpty { comps.queryItems = items }
        guard let url = comps.url else { throw APIError.notConfigured }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw APIError.transport(error.localizedDescription) }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
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

    func recordings(date: String, station: String?) async throws -> RecordingsResponse {
        var q = [URLQueryItem(name: "date", value: date)]
        if let s = station { q.append(.init(name: "station", value: s)) }
        return try await get("/recordings", q)
    }

    /// AVPlayer cannot easily carry an Authorization header, and the API
    /// accepts the token as a query parameter for exactly this case.
    func playbackURL(for rec: Recording) -> URL? {
        guard var c = URLComponents(string: rec.audioURL) else { return nil }
        c.queryItems = [URLQueryItem(name: "token", value: token)]
        return c.url
    }
}
