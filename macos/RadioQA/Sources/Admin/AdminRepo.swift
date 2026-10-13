import Foundation
import Observation
import FirebaseFirestore
import FirebaseStorage
import UniformTypeIdentifiers

/// Reads and writes one Firestore collection through the generic field model.
@MainActor
@Observable
final class AdminRepo {
    let spec: CollectionSpec
    private(set) var rows: [Row] = []
    private(set) var loading = false
    private(set) var error: String?

    struct Row: Identifiable, Equatable {
        let id: String
        var values: [String: FieldValue]
        func display(_ field: String) -> String { values[field]?.asString ?? "" }
    }

    init(spec: CollectionSpec) { self.spec = spec }

    private var db: Firestore { Firestore.firestore() }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let snap = try await db.collection(spec.key).getDocuments()
            var out = snap.documents.map { doc in
                Row(id: doc.documentID,
                    values: doc.data().mapValues { FieldValue.from($0) })
            }
            // Sorted here, not on the server - the web admin never sorted
            // server-side and the data has no matching indexes.
            if spec.hasOrder {
                out.sort { a, b in
                    let x = a.values["order"]?.asDouble ?? 0
                    let y = b.values["order"]?.asDouble ?? 0
                    if x != y { return x < y }
                    return a.display(spec.searchField) < b.display(spec.searchField)
                }
            } else {
                out.sort { $0.display(spec.searchField) < $1.display(spec.searchField) }
            }
            rows = out
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Writes every configured field, storing "" for empty optionals so the
    /// shape matches what the website reads.
    func save(id: String?, values: [String: FieldValue]) async -> Bool {
        error = nil
        var payload: [String: Any] = [:]
        for f in spec.fields {
            let v = values[f.name] ?? f.defaultValue
            switch f.kind {
            case .checkbox:            payload[f.name] = v.asBool
            case .number:              payload[f.name] = v.asDouble
            default:                   payload[f.name] = v.asString
            }
        }
        do {
            if let id {
                try await db.collection(spec.key).document(id).setData(payload, merge: true)
            } else {
                payload["createdAt"] = ISO8601DateFormatter().string(from: Date())
                _ = try await db.collection(spec.key).addDocument(data: payload)
            }
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(id: String) async -> Bool {
        error = nil
        do {
            try await db.collection(spec.key).document(id).delete()
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Uploads to `<folder>/<epochMillis>_<filename>` with the long cache
    /// header the existing files use, and returns the download URL.
    func upload(_ fileURL: URL) async -> String? {
        guard let folder = spec.storagePath else { return nil }
        error = nil
        let name = fileURL.lastPathComponent
        let path = "\(folder)/\(Int(Date().timeIntervalSince1970 * 1000))_\(name)"
        let meta = StorageMetadata()
        meta.cacheControl = "public, max-age=31536000, immutable"
        meta.contentType = UTType(filenameExtension: fileURL.pathExtension)?
            .preferredMIMEType ?? "application/octet-stream"
        do {
            let ref = Storage.storage().reference(withPath: path)
            _ = try await ref.putFileAsync(from: fileURL, metadata: meta)
            return try await ref.downloadURL().absoluteString
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Unfiltered server-side count, as the dashboard uses.
    static func count(_ collection: String) async -> Int? {
        try? await Firestore.firestore().collection(collection)
            .count.getAggregation(source: .server).count.intValue
    }
}
