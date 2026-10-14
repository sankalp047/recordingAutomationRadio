import Foundation

extension Dictionary where Key == String, Value == Any {
    /// Identity for a BigFan document in a SwiftUI List. The row index is not
    /// usable: it stays the same when the underlying collection changes, so
    /// SwiftUI reuses rows that hold different records.
    var bigfanRowID: String { self["id"] as? String ?? UUID().uuidString }
}
