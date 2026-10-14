import Foundation
import Observation
import UniformTypeIdentifiers

/// Reads and writes one Firestore collection over REST.
@MainActor
@Observable
final class AdminRepo {
    let spec: CollectionSpec
    private let session: AdminSession
    private(set) var rows: [Row] = []
    private(set) var loading = false
    private(set) var error: String?

    struct Row: Identifiable, Equatable {
        let id: String
        var values: [String: FieldValue]
        func display(_ field: String) -> String { values[field]?.asString ?? "" }
    }

    init(spec: CollectionSpec, session: AdminSession) {
        self.spec = spec
        self.session = session
    }

    private func ready() async -> (String, FirebaseREST.Config)? {
        guard let config = session.firebaseConfig, let token = await session.validToken()
        else { error = "Not signed in."; return nil }
        return (token, config)
    }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        guard let (token, config) = await ready() else { return }
        do {
            let docs = try await FirebaseREST.list(collection: spec.key, token: token, config: config)
            var out = docs.map { Row(id: $0.id, values: $0.fields.mapValues { FieldValue.from($0) }) }
            // Sorted here, not on the server: the web admin never sorted
            // server-side and there are no matching indexes.
            if spec.hasOrder {
                out.sort {
                    let x = $0.values["order"]?.asDouble ?? 0, y = $1.values["order"]?.asDouble ?? 0
                    return x == y ? $0.display(spec.searchField) < $1.display(spec.searchField) : x < y
                }
            } else {
                out.sort { $0.display(spec.searchField) < $1.display(spec.searchField) }
            }
            rows = out
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Writes every configured field, storing "" for empty optionals so the
    /// shape matches what the website reads.
    func save(id: String?, values: [String: FieldValue]) async -> Bool {
        error = nil
        guard let (token, config) = await ready() else { return false }
        var payload: [String: Any] = [:]
        for f in spec.fields {
            let v = values[f.name] ?? f.defaultValue
            switch f.kind {
            case .checkbox: payload[f.name] = v.asBool
            case .number:   payload[f.name] = v.asDouble
            default:        payload[f.name] = v.asString
            }
        }
        do {
            if let id {
                try await FirebaseREST.update(path: "\(spec.key)/\(id)", fields: payload,
                                              token: token, config: config)
            } else {
                payload["createdAt"] = ISO8601DateFormatter().string(from: Date())
                try await FirebaseREST.create(collection: spec.key, fields: payload,
                                              token: token, config: config)
            }
            await load()
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func delete(id: String) async -> Bool {
        error = nil
        guard let (token, config) = await ready() else { return false }
        do {
            try await FirebaseREST.delete(path: "\(spec.key)/\(id)", token: token, config: config)
            await load()
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Uploads to `<folder>/<epochMillis>_<filename>` and returns the download URL.
    func upload(_ fileURL: URL) async -> String? {
        guard let folder = spec.storagePath else { return nil }
        error = nil
        guard let (token, config) = await ready() else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else {
            error = "Could not read that file."; return nil
        }
        let name = fileURL.lastPathComponent
        let path = "\(folder)/\(Int(Date().timeIntervalSince1970 * 1000))_\(name)"
        let type = UTType(filenameExtension: fileURL.pathExtension)?
            .preferredMIMEType ?? "application/octet-stream"
        do {
            return try await FirebaseREST.upload(data: data, to: path, contentType: type,
                                                 token: token, config: config)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    static func count(_ collection: String, session: AdminSession) async -> Int? {
        guard let config = session.firebaseConfig, let token = await session.validToken()
        else { return nil }
        return try? await FirebaseREST.count(collection: collection, token: token, config: config)
    }
}
