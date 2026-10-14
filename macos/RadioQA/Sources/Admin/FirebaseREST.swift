import Foundation

/// Firebase over plain HTTPS, instead of the Firebase SDK.
///
/// The SDK's Auth component stores its session with `SecItemAdd` under a
/// keychain access group, which needs the `keychain-access-groups`
/// entitlement. That entitlement is restricted: Xcode will not build it
/// without a provisioning profile, and macOS refuses to launch a binary that
/// claims it without one. Both require a paid Apple Developer team, so on an
/// internally distributed build the SDK simply cannot sign in — it fails
/// -34018 before the password is even checked.
///
/// These REST endpoints are the same ones the SDK calls. They need no
/// entitlement, no provisioning profile, and no keychain group: the refresh
/// token is kept in the app's own keychain item, which it owns outright.
enum FirebaseREST {

    // MARK: config, read from the bundled GoogleService-Info.plist

    struct Config {
        let apiKey: String
        let projectId: String
        let storageBucket: String

        static func load() -> Config? {
            guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
                  let d = NSDictionary(contentsOf: url),
                  let key = d["API_KEY"] as? String,
                  let project = d["PROJECT_ID"] as? String
            else { return nil }
            return Config(apiKey: key, projectId: project,
                          storageBucket: d["STORAGE_BUCKET"] as? String ?? "")
        }
    }

    enum Failure: LocalizedError {
        case notConfigured
        case message(String)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Firebase is not configured in this build."
            case .message(let m): return m
            case .http(let c, let m): return m.isEmpty ? "Request failed (\(c))" : m
            }
        }
    }

    // MARK: sign-in

    struct Session {
        let idToken: String
        let refreshToken: String
        let uid: String
        let email: String
        let expiresAt: Date
        var isFresh: Bool { expiresAt > Date().addingTimeInterval(60) }
    }

    static func signIn(email: String, password: String, config: Config) async throws -> Session {
        let body: [String: Any] = ["email": email, "password": password, "returnSecureToken": true]
        let json = try await post(
            "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(config.apiKey)",
            body: body)
        guard let idToken = json["idToken"] as? String,
              let refresh = json["refreshToken"] as? String,
              let uid = json["localId"] as? String
        else { throw Failure.message("The sign-in response was not understood.") }
        let expiresIn = Double(json["expiresIn"] as? String ?? "3600") ?? 3600
        return Session(idToken: idToken, refreshToken: refresh, uid: uid,
                       email: json["email"] as? String ?? email,
                       expiresAt: Date().addingTimeInterval(expiresIn))
    }

    static func refresh(_ refreshToken: String, config: Config) async throws -> Session {
        let form = "grant_type=refresh_token&refresh_token=\(refreshToken)"
        var req = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(config.apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.data(using: .utf8)
        let json = try await send(req)
        guard let idToken = json["id_token"] as? String,
              let newRefresh = json["refresh_token"] as? String,
              let uid = json["user_id"] as? String
        else { throw Failure.message("Could not refresh the session.") }
        let expiresIn = Double(json["expires_in"] as? String ?? "3600") ?? 3600
        return Session(idToken: idToken, refreshToken: newRefresh, uid: uid, email: "",
                       expiresAt: Date().addingTimeInterval(expiresIn))
    }

    // MARK: Firestore

    private static func docsURL(_ config: Config, _ path: String) -> String {
        "https://firestore.googleapis.com/v1/projects/\(config.projectId)/databases/(default)/documents/\(path)"
    }

    /// Every document in a collection. Firestore pages at 300 here; the admin
    /// collections are small and the web admin never paged either.
    static func list(collection: String, token: String, config: Config) async throws -> [(id: String, fields: [String: Any])] {
        var out: [(String, [String: Any])] = []
        var pageToken: String?
        repeat {
            var s = docsURL(config, collection) + "?pageSize=300"
            if let t = pageToken { s += "&pageToken=\(t)" }
            let json = try await get(s, token: token)
            for case let doc as [String: Any] in (json["documents"] as? [Any] ?? []) {
                guard let name = doc["name"] as? String else { continue }
                out.append((String(name.split(separator: "/").last ?? ""),
                            decode(doc["fields"] as? [String: Any] ?? [:])))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return out
    }

    static func getDoc(path: String, token: String, config: Config) async throws -> [String: Any]? {
        do {
            let json = try await get(docsURL(config, path), token: token)
            return decode(json["fields"] as? [String: Any] ?? [:])
        } catch Failure.http(404, _) {
            return nil
        }
    }

    static func create(collection: String, fields: [String: Any], token: String, config: Config) async throws {
        _ = try await post(docsURL(config, collection), body: ["fields": encode(fields)], token: token)
    }

    /// PATCH with an explicit updateMask, so fields absent from the payload are
    /// left alone rather than silently cleared.
    static func update(path: String, fields: [String: Any], token: String, config: Config) async throws {
        let mask = fields.keys.map { "updateMask.fieldPaths=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" }
            .joined(separator: "&")
        var req = URLRequest(url: URL(string: docsURL(config, path) + "?" + mask)!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": encode(fields)])
        _ = try await send(req)
    }

    static func delete(path: String, token: String, config: Config) async throws {
        var req = URLRequest(url: URL(string: docsURL(config, path))!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await send(req)
    }

    /// Server-side count, the same aggregation the dashboard used.
    static func count(collection: String, token: String, config: Config) async throws -> Int {
        let base = "https://firestore.googleapis.com/v1/projects/\(config.projectId)/databases/(default)/documents:runAggregationQuery"
        let body: [String: Any] = ["structuredAggregationQuery": [
            "structuredQuery": ["from": [["collectionId": collection]]],
            "aggregations": [["alias": "n", "count": [:]]],
        ]]
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return 0 }
        for row in arr {
            if let r = row["result"] as? [String: Any],
               let agg = r["aggregateFields"] as? [String: Any],
               let n = agg["n"] as? [String: Any],
               let v = n["integerValue"] as? String { return Int(v) ?? 0 }
        }
        return 0
    }

    // MARK: Storage

    /// Uploads and returns the public download URL, matching the path and
    /// cache header the existing files use.
    static func upload(data: Data, to path: String, contentType: String,
                       token: String, config: Config) async throws -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
        let url = "https://firebasestorage.googleapis.com/v0/b/\(config.storageBucket)/o?uploadType=media&name=\(encoded)"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("public, max-age=31536000, immutable", forHTTPHeaderField: "Cache-Control")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        let json = try await send(req)
        let tok = (json["downloadTokens"] as? String) ?? ""
        return "https://firebasestorage.googleapis.com/v0/b/\(config.storageBucket)/o/\(encoded)?alt=media"
            + (tok.isEmpty ? "" : "&token=\(tok)")
    }

    // MARK: value mapping

    /// Firestore REST wraps every value in a type tag. Mapping is lenient on
    /// the way in because `order` appears as an integer, a double and "" in the
    /// live data.
    static func decode(_ fields: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in fields {
            guard let w = v as? [String: Any], let (kind, raw) = w.first else { continue }
            switch kind {
            case "stringValue":    out[k] = raw as? String ?? ""
            case "booleanValue":   out[k] = raw as? Bool ?? false
            case "integerValue":   out[k] = Double(raw as? String ?? "0") ?? 0
            case "doubleValue":    out[k] = (raw as? NSNumber)?.doubleValue ?? 0
            case "timestampValue": out[k] = raw as? String ?? ""
            case "nullValue":      out[k] = ""
            case "arrayValue":
                // galleries store [{url, caption}], marketplace stores [String]
                let vals = (raw as? [String: Any])?["values"] as? [Any] ?? []
                out[k] = vals.compactMap { unwrap($0) }
            case "mapValue":
                out[k] = decode((raw as? [String: Any])?["fields"] as? [String: Any] ?? [:])
            default:               continue
            }
        }
        return out
    }

    /// One Firestore-typed value back to a plain Swift value.
    private static func unwrap(_ any: Any) -> Any? {
        guard let w = any as? [String: Any], let (kind, raw) = w.first else { return nil }
        switch kind {
        case "stringValue":  return raw as? String ?? ""
        case "booleanValue": return raw as? Bool ?? false
        case "integerValue": return Double(raw as? String ?? "0") ?? 0
        case "doubleValue":  return (raw as? NSNumber)?.doubleValue ?? 0
        case "mapValue":     return decode((raw as? [String: Any])?["fields"] as? [String: Any] ?? [:])
        case "arrayValue":
            let vals = (raw as? [String: Any])?["values"] as? [Any] ?? []
            return vals.compactMap { unwrap($0) }
        default:             return nil
        }
    }

    private static func wrap(_ v: Any) -> [String: Any] {
        switch v {
        case let b as Bool:   return ["booleanValue": b]
        case let d as Double: return d == d.rounded() ? ["integerValue": String(Int(d))] : ["doubleValue": d]
        case let i as Int:    return ["integerValue": String(i)]
        case let s as String: return ["stringValue": s]
        case let a as [Any]:  return ["arrayValue": ["values": a.map { wrap($0) }]]
        case let m as [String: Any]: return ["mapValue": ["fields": m.mapValues { wrap($0) }]]
        default:              return ["stringValue": String(describing: v)]
        }
    }

    static func encode(_ fields: [String: Any]) -> [String: Any] {
        fields.mapValues { wrap($0) }
    }

    // MARK: transport

    private static func get(_ url: String, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    private static func post(_ url: String, body: [String: Any], token: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw Failure.message(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let err = json["error"] as? [String: Any]
            throw Failure.http(code, friendly(err?["message"] as? String ?? ""))
        }
        return json
    }

    /// Identity Toolkit returns machine codes; turn the ones people actually
    /// hit into something readable.
    private static func friendly(_ raw: String) -> String {
        switch raw.split(separator: ":").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? raw {
        case "EMAIL_NOT_FOUND":       return "No account with that email address."
        case "INVALID_PASSWORD",
             "INVALID_LOGIN_CREDENTIALS": return "Wrong email or password."
        case "USER_DISABLED":         return "That account has been disabled."
        case "TOO_MANY_ATTEMPTS_TRY_LATER": return "Too many attempts. Wait a few minutes."
        case "PERMISSION_DENIED":     return "Firestore refused the request. Check the security rules."
        default:                      return raw.isEmpty ? "Request failed." : raw
        }
    }
}
