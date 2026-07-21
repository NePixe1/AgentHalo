import Foundation

/// Raw-object JSON helpers for credential files. Uses `JSONSerialization` so
/// unrelated keys are preserved on round-trip — `set` updates only the
/// requested nested path and leaves every other key untouched. The helpers
/// never log the object contents.
enum CredentialJSON {
    /// Parse `data` into a raw JSON object.
    static func object(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = object as? [String: Any] else {
            throw CredentialJSONError.rootIsNotObject
        }
        return dict
    }

    /// Serialize a raw JSON object. When `prettyPrinted` is true the output
    /// is sorted and human-readable for diffing.
    static func data(from object: [String: Any], prettyPrinted: Bool) throws -> Data {
        var options: JSONSerialization.WritingOptions = []
        if prettyPrinted {
            options.insert([.prettyPrinted, .sortedKeys])
        }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    /// Read a string at a nested path (e.g. `["token", "access_token"]`).
    /// Returns `nil` if any segment is missing or the leaf is not a string.
    static func string(_ object: [String: Any], path: [String]) -> String? {
        guard !path.isEmpty else { return nil }
        var current: Any = object
        for (index, key) in path.enumerated() {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            if index == path.count - 1 {
                return next as? String
            }
            current = next
        }
        return nil
    }

    /// Write `value` at a nested path, creating intermediate dictionaries as
    /// needed. Only the requested path is mutated; every unrelated key in
    /// `object` is left untouched.
    static func set(_ value: Any?, path: [String], in object: inout [String: Any]) {
        guard !path.isEmpty else { return }
        setInPlace(value, path: path, object: &object, depth: 0)
    }

    private static func setInPlace(_ value: Any?, path: [String], object: inout [String: Any], depth: Int) {
        guard depth < path.count else { return }
        let key = path[depth]
        if depth == path.count - 1 {
            if value == nil {
                object.removeValue(forKey: key)
            } else {
                object[key] = value
            }
            return
        }
        var nested = (object[key] as? [String: Any]) ?? [:]
        setInPlace(value, path: path, object: &nested, depth: depth + 1)
        object[key] = nested
    }
}

enum CredentialJSONError: Error, Equatable {
    case rootIsNotObject
}
