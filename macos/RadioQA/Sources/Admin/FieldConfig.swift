import Foundation

/// Most admin screens are a field list handed to one editor, mirroring the
/// web admin's generic CRUD component (handoff 6.3).
enum FieldKind: Equatable {
    case text
    case textarea
    case url
    case number
    case checkbox
    case select([String])
    case image          // upload to Storage, store the download URL
    case datetimeLocal  // "YYYY-MM-DDTHH:mm", no time zone
}

struct FieldConfig: Identifiable, Equatable {
    let name: String
    let label: String
    let kind: FieldKind
    var required: Bool = false
    var defaultValue: FieldValue = .string("")
    var help: String?
    var id: String { name }
}

/// Values round-trip through Firestore unchanged. Empty optional fields are
/// stored as "" rather than omitted, because that is what the existing data
/// and the website both expect (handoff 6.3, rule 2).
enum FieldValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    var asString: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b):   return b ? "true" : "false"
        }
    }
    var asDouble: Double {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s) ?? 0
        case .bool(let b):   return b ? 1 : 0
        }
    }
    var asBool: Bool {
        switch self {
        case .bool(let b):   return b
        case .string(let s): return s == "true"
        case .number(let n): return n != 0
        }
    }

    /// `order` is Int, Double or "" in the live data, so decode leniently
    /// (handoff 6.3, rule 4).
    static func from(_ any: Any?) -> FieldValue {
        switch any {
        case let b as Bool:   return .bool(b)
        case let i as Int:    return .number(Double(i))
        case let d as Double: return .number(d)
        case let n as NSNumber: return .number(n.doubleValue)
        case let s as String: return .string(s)
        default:              return .string("")
        }
    }
}

/// One admin collection: where it lives, how to show it, what it contains.
struct CollectionSpec: Identifiable, Equatable {
    let key: String              // Firestore collection
    let title: String
    let icon: String
    let storagePath: String?     // Storage folder for .image fields
    let searchField: String
    let superadminOnly: Bool
    let fields: [FieldConfig]
    var id: String { key }

    /// Lists are sorted in memory; the admin never sorted server-side
    /// (handoff 6.3, rule 6).
    var hasOrder: Bool { fields.contains { $0.name == "order" } }
}
