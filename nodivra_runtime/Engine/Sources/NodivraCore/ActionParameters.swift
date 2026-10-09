import Foundation

/// A configuration field retains its fixed value while an explicit, typed pin supplies it.
public struct ActionParameter: Codable, Equatable, Sendable {
    public var path: [ConfigurationPath]
    public var type: SignalType
    public var label: String
    public var minimum: Double?
    public var maximum: Double?
    public var choices: [ConfigValue]?
    public init(path: [ConfigurationPath], type: SignalType, label: String, minimum: Double? = nil, maximum: Double? = nil, choices: [ConfigValue]? = nil) {
        self.path = path; self.type = type; self.label = label; self.minimum = minimum; self.maximum = maximum; self.choices = choices
    }
    public static func allows(_ path: [ConfigurationPath]) -> Bool {
        guard let first = path.first, case .key(let key) = first else { return false }
        return ["data", "target", "delay"].contains(key)
    }
    public func accepts(_ value: ConfigValue) -> Bool {
        guard type.accepts(value), value.json.utf8.count <= 65536 else { return false }
        if let n = value.number {
            if let minimum, n < minimum { return false }
            if let maximum, n > maximum { return false }
        }
        return choices?.isEmpty != false || choices!.contains(value)
    }
}

public extension SignalType {
    var label: String { switch self { case .digital: "Ein/Aus"; case .analog: "Zahl"; case .text: "Text"; case .list: "Liste"; case .object: "Objekt" } }
    var initial: ConfigValue { switch self { case .digital: .bool(false); case .analog: .number(0); case .text: .string(""); case .list: .array([]); case .object: .object([:]) } }
    static func of(_ value: ConfigValue) -> SignalType? {
        switch value { case .bool: .digital; case .number: .analog; case .string: .text; case .array: .list; case .object: .object; case .null: nil }
    }
    func accepts(_ value: ConfigValue) -> Bool {
        guard Self.of(value) == self else { return false }
        func finite(_ v: ConfigValue) -> Bool {
            switch v { case .number(let n): n.isFinite; case .array(let a): a.allSatisfy(finite); case .object(let o): o.values.allSatisfy(finite); default: true }
        }
        return finite(value)
    }
}

public extension Block {
    var actionParameters: [ActionParameter] {
        get { guard let value = options["parameterBindings"], let data = try? JSONEncoder().encode(value) else { return [] }; return (try? JSONDecoder().decode([ActionParameter].self, from: data)) ?? [] }
        set { options["parameterBindings"] = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue)).flatMap { try? JSONDecoder().decode(ConfigValue.self, from: $0) } }
    }
    var hasActionParameters: Bool { kind == .haAction && !actionParameters.isEmpty }
    var selectionType: SignalType {
        switch text("valueUnit", "duration") { case "boolean": .digital; case "text": .text; case "list": .list; case "object": .object; default: .analog }
    }
    var typedSelection: Bool { function == .valueSelect && !["duration", "number"].contains(text("valueUnit", "duration")) }
    func selectedValue(_ key: String) -> ConfigValue { options[key] ?? (selectionType == .analog ? .number(key == "defaultValue" ? 300 : 120) : selectionType.initial) }
    var parameterErrors: [String] {
        guard let raw = options["parameterBindings"] else { return [] }
        guard kind == .haAction, let data = try? JSONEncoder().encode(raw), let parsed = try? JSONDecoder().decode([ActionParameter].self, from: data), parsed.count <= 32 else { return ["Ungültige Parameteranschlüsse (höchstens 32)."] }
        var errors: [String] = []
        for (i, p) in parsed.enumerated() {
            if !ActionParameter.allows(p.path) || configuration.at(p.path) == nil || p.path.count > 16 { errors.append("\(p.label): Das verknüpfte Feld fehlt oder ist kein Aktionsparameter.") }
            if p.minimum?.isFinite == false || p.maximum?.isFinite == false || (p.minimum ?? -Double.greatestFiniteMagnitude) > (p.maximum ?? Double.greatestFiniteMagnitude) { errors.append("\(p.label): Ungültiger Wertebereich.") }
            if parsed.prefix(i).contains(where: { $0.path.starts(with: p.path) || p.path.starts(with: $0.path) }) { errors.append("\(p.label): Ein Feld und seine Unterfelder können nicht gleichzeitig verknüpft werden.") }
        }
        return errors
    }
    /// Resolves every field atomically. A missing wire never falls back to an old fixed value.
    func resolvingParameters(_ input: (Int, SignalType) -> ConfigValue?, frozenTarget: ConfigValue? = nil) -> ConfigValue? {
        var result = configuration
        for (index, parameter) in actionParameters.enumerated() {
            if parameter.path.first == .key("target"), let frozenTarget { result = result.setting("target", to: frozenTarget); continue }
            guard let value = input(index + 1, parameter.type), parameter.accepts(value) else { return nil }
            result = result.replacing(parameter.path, with: value)
        }
        return result
    }
}

public extension AutomationGraph {
    var usesActionParameters: Bool { blocks.contains { $0.options["parameterBindings"] != nil || $0.typedSelection } }
}

extension RuntimeCompiler {
    // HA integrations perform their own final schema validation. These common fields
    // are checked locally as well, including when a whole data object is connected.
    static func validResolvedParameters(_ config: ConfigValue) -> Bool {
        guard config.json.utf8.count <= 131072 else { return false }
        if let target = config.object?["target"] {
            guard let fields = target.object, !fields.isEmpty,
                  fields.values.allSatisfy({ value in
                      let ids = SignalBridge.strings(value)
                      return !ids.isEmpty && ids.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                  }) else { return false }
        }
        let data = config.object?["data"]?.object ?? [:]
        if service(config) == "light.turn_on" {
            for (key, range) in [("brightness_pct", 0.0...100), ("brightness", 0.0...255), ("transition", 0.0...6553), ("color_temp_kelvin", 1.0...100000)] {
                if let v = data[key], v.number.map({ $0.isFinite && range.contains($0) }) != true { return false }
            }
            if let rgb = data["rgb_color"], rgb.array?.count != 3 || rgb.array?.allSatisfy({ $0.number.map { $0.isFinite && (0...255).contains($0) } == true }) != true { return false }
        }
        return true
    }
}
