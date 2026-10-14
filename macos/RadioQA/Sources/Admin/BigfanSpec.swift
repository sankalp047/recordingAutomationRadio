import Foundation

/// Field configuration for the BigFan screens, decoded from the bundled
/// `bigfan-collections.json` — generated from the same file the server uses
/// to validate writes, so the form and the validator cannot drift.
struct BigfanSpec: Decodable, Identifiable {
    let key: String
    let collectionName: String
    let title: String
    var searchField: String?
    var sortField: String?
    var sortDirection: String?
    var readonly: Bool?
    var patchableFields: [String]?
    let fields: [BigfanField]

    var id: String { key }
    var isReadOnly: Bool { readonly == true }
    /// A read-only collection that still allows one or two fields to change,
    /// e.g. reward-claims where only `status` may be patched.
    var patchOnly: [String] { patchableFields ?? [] }
    /// Lists show the first five configured fields, as the web admin does.
    var columns: [BigfanField] { Array(fields.prefix(5)) }
}

struct BigfanField: Decodable, Identifiable {
    let name: String
    let label: String
    let type: String
    var required: Bool?
    var options: [Option]?
    var placeholder: String?
    var defaultValue: JSONValue?
    var dependsOn: String?
    var showIf: ShowIf?

    var id: String { name }
    var isRequired: Bool { required == true }

    struct Option: Decodable, Hashable { let value: String; let label: String }
    struct ShowIf: Decodable { let field: String; let value: String }
}

/// `defaultValue` is a bool, number or string depending on the field.
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    var any: Any? {
        switch self {
        case .string(let s): return s
        case .number(let d): return d
        case .bool(let b):   return b
        case .null:          return nil
        }
    }
}

enum BigfanCatalog {
    private struct File: Decodable { let collections: [String: BigfanSpec] }

    /// Loaded once from the bundle.
    static let all: [String: BigfanSpec] = {
        guard let url = Bundle.main.url(forResource: "bigfan-collections", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        return file.collections
    }()

    static func spec(_ key: String) -> BigfanSpec? { all[key] }

    /// Blank form values for a new record, honouring each field's default.
    static func blank(_ spec: BigfanSpec) -> [String: Any] {
        var out: [String: Any] = [:]
        for f in spec.fields {
            if let d = f.defaultValue?.any { out[f.name] = d; continue }
            switch f.type {
            case "checkbox":              out[f.name] = false
            case "stringArray", "multiSelect": out[f.name] = [String]()
            case "socialLinks":           out[f.name] = [String: String]()
            case "number":                out[f.name] = 0.0
            default:                      out[f.name] = ""
            }
        }
        return out
    }
}

/// BigFan datetimes are entered in Dallas time and stored as UTC.
enum CentralTime {
    static let zone = TimeZone(identifier: "America/Chicago")!

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func toUTCString(_ date: Date) -> String { iso.string(from: date) }

    static func parse(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// `dd/MM/yyyy, h:mm a CT`, matching the web admin.
    static func display(_ isoUTC: String) -> String {
        guard let d = parse(isoUTC) else { return isoUTC }
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "dd/MM/yyyy, h:mm a 'CT'"
        return f.string(from: d)
    }

    static func displayDate(_ isoUTC: String) -> String {
        guard let d = parse(isoUTC) else { return isoUTC }
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "dd/MM/yyyy"
        return f.string(from: d)
    }
}
