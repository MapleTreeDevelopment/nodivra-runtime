import Foundation

/// Data only: no expressions, scripts, URLs or executable code are accepted by this schema.
public struct RuntimeBlockField: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case number, text, choice, toggle, entity }
    public var key: String
    public var label: String
    public var kind: Kind
    public var initial: ConfigValue
    public var minimum: Double?
    public var maximum: Double?
    public var choices: [String]
    public var id: String { key }
    public func accepts(_ value: ConfigValue) -> Bool {
        switch kind {
        case .number: return value.number.map { $0.isFinite && $0 >= (minimum ?? -1e9) && $0 <= (maximum ?? 1e9) } ?? false
        case .toggle: return value.bool != nil
        case .choice: return value.string.map { choices.contains($0) } ?? false
        case .text: return value.string.map { $0.utf8.count <= 4096 } ?? false
        case .entity: return value.string.map { $0.isEmpty || RuntimeCompiler.validEntity($0) } ?? false
        }
    }
}
public struct RuntimeBlockPort: Codable, Equatable, Sendable {
    public var label: String
    public var type: SignalType
    public var unconnected: ConfigValue?
}
/// A saved block carries its exact definition. Catalog refreshes never rewrite saved graphs.
public struct RuntimeBlockDefinition: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var id: String
    public var version: Int
    public var function: String
    public var title: String
    public var category: String
    public var summary: String
    public var icon: String
    public var inputs: [RuntimeBlockPort]
    public var outputs: [RuntimeBlockPort]
    public var fields: [RuntimeBlockField]
    public var valid: Bool {
        func identifier(_ s: String) -> Bool { s.range(of: "^[A-Za-z][A-Za-z0-9_.-]{0,95}$", options: .regularExpression) != nil }
        return schemaVersion == 1 && version > 0 && version <= 10000 && identifier(id) && identifier(function)
            && !title.isEmpty && title.count <= 120 && !category.isEmpty && category.count <= 80 && summary.count <= 2048
            && identifier(icon) && inputs.count <= 16 && (1...8).contains(outputs.count) && fields.count <= 32
            && Set(outputs.map(\.type)).count == outputs.count
            && outputs.filter { ![SignalType.digital, .analog].contains($0.type) }.count <= 1
            && Set(fields.map(\.key)).count == fields.count
            && fields.allSatisfy { identifier($0.key) && !["function", "inputCount"].contains($0.key) && !$0.label.isEmpty && $0.label.count <= 120 && $0.choices.count <= 100 && $0.choices.allSatisfy { $0.count <= 200 } && $0.minimum.map(\.isFinite) != false && $0.maximum.map(\.isFinite) != false && ($0.minimum ?? -1e9) <= ($0.maximum ?? 1e9) && $0.accepts($0.initial) }
            && (inputs + outputs).allSatisfy { !$0.label.isEmpty && $0.label.count <= 80 && ($0.unconnected == nil || ($0.type == .digital && $0.unconnected?.bool != nil)) }
    }
    public var descriptor: BlockDescriptor {
        .init(id: id, title: title, category: category, kind: .function, summary: summary,
              defaults: .object(Dictionary(uniqueKeysWithValues: [("function", .string(function))] + fields.map { ($0.key, $0.initial) })), requiredPaths: [], runtimeDefinition: self)
    }
    public func issues(for block: Block) -> [RuntimeIssue] {
        var messages: [String] = []
        if !valid || block.kind != .function || block.text("function") != function || block.catalogID != id { messages.append("Die gespeicherte Bausteinbeschreibung ist ungültig.") }
        if !Set(block.options.keys).isSubset(of: Set(fields.map(\.key) + ["function"])) { messages.append("Der Runtime-Baustein enthält unbekannte Einstellungen.") }
        for field in fields where !field.accepts(block.options[field.key] ?? field.initial) { messages.append("Ungültiger Wert: " + field.label) }
        return messages.map { .init($0, blockID: block.id) }
    }
}
public struct RuntimeBlockCatalog: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var definitions: [RuntimeBlockDefinition]
    public var valid: Bool {
        schemaVersion == 1 && definitions.count <= 512 && definitions.allSatisfy(\.valid)
            && Set(definitions.map { $0.id + ":" + String($0.version) }).count == definitions.count
    }
    public func definition(id: String, version: Int) -> RuntimeBlockDefinition? { definitions.first { $0.id == id && $0.version == version } }
    public var descriptors: [BlockDescriptor] {
        Dictionary(grouping: definitions, by: \.id).values.compactMap { $0.max { $0.version < $1.version }?.descriptor }.sorted { $0.id < $1.id }
    }
    /// Fixed-port functions use the generic inspector. Variable-port legacy editors remain native.
    /// Keep released definitions and implementations immutable; add a new version for semantic changes.
    public static let local = RuntimeBlockCatalog(definitions: PLCFunction.allCases.compactMap { function in
        guard ![.valueSelect, .nand, .nor, .andEdge, .nandEdge].contains(function) else { return nil }
        let block = function.descriptor.makeBlock()
        return RuntimeBlockDefinition(id: "plc." + function.rawValue, version: 1, function: function.rawValue,
            title: function.title, category: function.category, summary: function.summary, icon: "function",
            inputs: function.pins.enumerated().map { index, port in
                .init(label: port.0, type: port.1, unconnected: block.unusedDigitalInput(index).map(ConfigValue.bool))
            }, outputs: (0..<block.outputCount).map { .init(label: block.outputLabel($0), type: block.outputType($0)) },
            fields: function.parameters.map { parameter in
                .init(key: parameter.key, label: parameter.label, kind: parameter.range != nil ? .number : parameter.choices.isEmpty ? .text : .choice,
                      initial: parameter.initial, minimum: parameter.range?.lowerBound, maximum: parameter.range?.upperBound, choices: parameter.choices)
            })
    })
}
public extension Block {
    var runtimeDefinitionAvailableLocally: Bool {
        guard let definition = runtimeDefinition else { return true }
        return RuntimeBlockCatalog.local.definition(id: definition.id, version: definition.version) == definition
    }
    var displayTypeTitle: String { runtimeDefinition?.title ?? function?.title ?? kind.label }
    var displayIcon: String { runtimeDefinition?.icon ?? kind.icon }
}
