import Foundation

public indirect enum ConfigValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: ConfigValue]), array([ConfigValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([ConfigValue].self) { self = .array(x) }
        else { self = .object(try c.decode([String: ConfigValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let x) = self { return x }; return nil }
    public var number: Double? { if case .number(let x) = self { return x }; return nil }
    public var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    public var object: [String: ConfigValue]? { if case .object(let x) = self { return x }; return nil }
    public var array: [ConfigValue]? { if case .array(let x) = self { return x }; return nil }
    public var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }
    public static func parse(_ text: String) throws -> ConfigValue { try JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
    public func setting(_ key: String, to value: ConfigValue) -> ConfigValue {
        var object = self.object ?? [:]; object[key] = value; return .object(object)
    }
    public var yaml: String { YAMLWriter.render(self) + "\n" }
}

public enum YAMLWriter {
    public static func quote(_ value: String) -> String { String(decoding: try! JSONEncoder().encode(value), as: UTF8.self) }
    private static func scalar(_ value: ConfigValue) -> String? {
        switch value {
        case .string(let x): return quote(x)
        case .number(let x): return x.rounded() == x && abs(x) < 1e15 ? String(format: "%.0f", x) : String(x)
        case .bool(let x): return x ? "true" : "false"
        case .null: return "null"
        case .array(let x) where x.isEmpty: return "[]"
        case .object(let x) where x.isEmpty: return "{}"
        default: return nil
        }
    }
    private static let order = ["id", "alias", "description", "triggers", "conditions", "actions", "mode", "trigger", "condition", "action", "entity_id", "target", "data", "choose", "sequence", "default"]
    public static func render(_ value: ConfigValue, indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        if let scalar = scalar(value) { return pad + scalar }
        switch value {
        case .object(let dictionary):
            let keys = dictionary.keys.sorted {
                let a = order.firstIndex(of: $0) ?? 999, b = order.firstIndex(of: $1) ?? 999
                return a == b ? $0 < $1 : a < b
            }
            return keys.map { key in
                let reserved = ["y", "yes", "n", "no", "true", "false", "on", "off", "null"]
                let safeKey = key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && !reserved.contains(key.lowercased())
                let label = safeKey ? key : quote(key)
                let item = dictionary[key]!
                if let scalar = scalar(item) { return pad + label + ": " + scalar }
                return pad + label + ":\n" + render(item, indent: indent + 2)
            }.joined(separator: "\n")
        case .array(let array):
            return array.map { item in
                if let scalar = scalar(item) { return pad + "- " + scalar }
                return pad + "- " + String(render(item, indent: indent + 2).dropFirst(indent + 2))
            }.joined(separator: "\n")
        default: return pad + "null"
        }
    }
}
func str(_ value: String) -> ConfigValue { .string(value) }
func object(_ values: [String: ConfigValue]) -> ConfigValue { .object(values) }
func array(_ values: [ConfigValue]) -> ConfigValue { .array(values) }
