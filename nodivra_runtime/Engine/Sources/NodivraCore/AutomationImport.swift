import Foundation

public enum ImportCompatibility: String, Codable, Sendable, CaseIterable {
    case editable, preserved, reference, unavailable
    public var label: String {
        switch self {
        case .editable: "Als Blöcke bearbeitbar"
        case .preserved: "Erweiterte Blöcke"
        case .reference: "Nur Originalansicht"
        case .unavailable: "Konfiguration nicht abrufbar"
        }
    }
}
public struct ImportContext: Codable, Equatable, Sendable {
    public var entityID: String
    public var server: String
    public var original: ConfigValue
    public var triggerIDs: [UUID]
    public var conditionIDs: [UUID]
    public var actionIDs: [UUID]
    public var graphCompiled: Bool?
    public var originalTitles: [String: String]
    public init(entityID: String, server: String, original: ConfigValue, triggerIDs: [UUID], conditionIDs: [UUID], actionIDs: [UUID], originalTitles: [String: String]) {
        self.entityID = entityID; self.server = server; self.original = original
        self.triggerIDs = triggerIDs; self.conditionIDs = conditionIDs; self.actionIDs = actionIDs; self.originalTitles = originalTitles
    }
}
public struct AutomationImportResult: Sendable {
    public var compatibility: ImportCompatibility
    public var graph: AutomationGraph?
    public var notes: [String]
    public init(compatibility: ImportCompatibility, graph: AutomationGraph? = nil, notes: [String]) {
        self.compatibility = compatibility; self.graph = graph; self.notes = notes
    }
}
public enum AutomationImporter {
    private static let triggers: Set<String> = ["state","numeric_state","time","time_pattern","sun","event","mqtt","device","zone","geo_location","homeassistant","webhook","tag","template","calendar","conversation","persistent_notification"]
    private static let conditions: Set<String> = ["state","numeric_state","time","sun","zone","device","trigger","template","and","or","not"]
    public static func items(_ raw: ConfigValue, plural: String, singular: String) -> [ConfigValue] {
        guard let value = raw.object?[plural] ?? raw.object?[singular], value != .null else { return [] }
        return value.array ?? [value]
    }
    public static func inspect(_ raw: ConfigValue, entityID: String, server: String = "") -> AutomationImportResult {
        guard let root = raw.object else { return .init(compatibility: .reference, notes: ["Die Konfiguration ist kein Automationsobjekt."]) }
        if root["use_blueprint"] != nil {
            let b = Block(kind: .haAction, title: root["alias"]?.string ?? "Blueprint", x: 80, y: 80, options: ["configuration": raw, "blueprint": .bool(true)])
            var graph = AutomationGraph(title: root["alias"]?.string ?? entityID, blocks: [b], wires: [])
            graph.importContext = .init(entityID: entityID, server: server, original: raw, triggerIDs: [], conditionIDs: [], actionIDs: [b.id], originalTitles: [b.id.uuidString:b.title])
            return .init(compatibility: .preserved, graph: graph, notes: ["Blueprint mit bearbeitbaren Eingaben. Die Verknüpfung bleibt erhalten; der interne Ablauf liegt in der Blueprint-Datei und wird hier nicht aufgelöst."])
        }
        if ["trigger","condition","action"].contains(where: { root[$0] != nil && root[$0 + "s"] != nil }) {
            return .init(compatibility: .reference, notes: ["Alte und neue Schlüsselnamen sind gleichzeitig vorhanden. Die Bedeutung muss zuerst in Home Assistant geklärt werden."])
        }
        let ts = items(raw, plural: "triggers", singular: "trigger")
        let cs = items(raw, plural: "conditions", singular: "condition")
        let acts = items(raw, plural: "actions", singular: "action")
        guard !acts.isEmpty, ts.count + cs.count + acts.count <= 499 else {
            return .init(compatibility: .reference, notes: ["Für eine Blockdarstellung werden Aktionen sowie höchstens 499 Hauptbausteine benötigt."])
        }
        var blocks: [Block] = [], triggerIDs: [UUID] = [], conditionIDs: [UUID] = [], actionIDs: [UUID] = []
        var titles: [String: String] = [:], notes: [String] = []
        var partial = false
        func add(_ config: ConfigValue, kind: BlockKind, ordinal: Int, section: String) -> UUID? {
            let shorthand = kind == .haCondition && (config.string != nil || config.bool != nil || config.array != nil)
            guard let object = config.object ?? (shorthand ? [:] : nil) else { return nil }
            let type = kind == .haTrigger ? object["trigger"]?.string ?? object["platform"]?.string : kind == .haCondition ? object["condition"]?.string : object["action"]?.string ?? object["service"]?.string
            if kind == .haTrigger && (type == nil || !triggers.contains(type!)) { partial = true }
            if kind == .haCondition && (type == nil || !conditions.contains(type!)) { partial = true }
            if kind == .haAction && !HAConfiguration.actionKeys.contains(where: { object[$0] != nil }) { partial = true }
            if object["enabled"] == .bool(false) || hasComplexValue(config) { partial = true }
            let label = HAConfiguration.title(config, role: kind)
            let actionPosition = ordinal + cs.count
            let x = kind == .haTrigger ? 50.0 : 360.0 + Double(actionPosition % 9) * 300
            let y = kind == .haTrigger ? 50.0 + Double(ordinal) * 270 : 150.0 + Double(actionPosition / 9) * 280
            let b = Block(kind: kind, title: label, x: x, y: y, options: ["configuration": config, "importSection": .string(section)])
            blocks.append(b); titles[b.id.uuidString] = label; return b.id
        }
        if ts.isEmpty {
            let b = Block(kind: .haTrigger, title: "Manuell / extern gestartet", x: 50, y: 50, options: ["manualStart": .bool(true), "configuration": .object(["trigger": .string("nodivra_manual")])])
            blocks.append(b); triggerIDs.append(b.id); titles[b.id.uuidString] = b.title
            notes.append("Keine automatischen Auslöser eingerichtet. Ein Start ist nur manuell oder durch einen anderen Aufruf möglich. Der Startblock wird nicht als HA-Auslöser exportiert.")
        }
        for (i, config) in ts.enumerated() {
            guard let id = add(config, kind: .haTrigger, ordinal: i, section: "triggers") else { return .init(compatibility: .reference, notes: ["Mindestens ein Auslöser verwendet eine noch nicht darstellbare Struktur. Das Original bleibt vollständig erhalten."]) }
            triggerIDs.append(id)
        }
        for (i, config) in cs.enumerated() {
            guard let id = add(config, kind: .haCondition, ordinal: i - cs.count, section: "conditions") else { return .init(compatibility: .reference, notes: ["Eine globale Bedingung verwendet eine Kurzschreibweise oder Struktur, die noch nicht verlustfrei als Block bearbeitet werden kann."]) }
            conditionIDs.append(id)
        }
        for (i, config) in acts.enumerated() {
            let kind: BlockKind = (config.object?["condition"] != nil || config.string != nil || config.bool != nil || ["and","or","not"].contains(where: { config.object?[$0] != nil })) ? .haCondition : .haAction
            guard let id = add(config, kind: kind, ordinal: i, section: "actions") else { return .init(compatibility: .reference, notes: ["Mindestens eine Aktion ist strukturell noch nicht unterstützt. Das Original wird nicht verändert."]) }
            actionIDs.append(id)
        }
        let chain = conditionIDs + actionIDs
        var wires = triggerIDs.map { Wire(source: $0, target: chain[0], input: 0) }
        for pair in zip(chain, chain.dropFirst()) { wires.append(.init(source: pair.0, target: pair.1, input: 0)) }
        var graph = AutomationGraph(title: root["alias"]?.string ?? entityID, blocks: blocks, wires: wires)
        graph.importContext = .init(entityID: entityID, server: server, original: raw, triggerIDs: triggerIDs, conditionIDs: conditionIDs, actionIDs: actionIDs, originalTitles: titles)
        if partial { notes.append("Verschachtelte Abläufe lassen sich als Unterblöcke öffnen. Templates und integrationsabhängige Felder bleiben vollständig erhalten und sind im Eigenschaftenbereich bearbeitbar. Die Ausführbarkeit prüft Home Assistant.") }
        notes.append("Importiert werden Arbeitskopien. Modus, Variablen, Trigger-IDs und globale Bedingungen bleiben erhalten.")
        if !GraphValidator.validate(graph).isEmpty { partial = true; notes.append("Die importierte Struktur enthält offene Prüfpunkte. Der Editor zeigt sie an; ein Export ist erst nach der Korrektur möglich.") }
        return .init(compatibility: partial ? .preserved : .editable, graph: graph, notes: notes)
    }
    private static func hasComplexValue(_ value: ConfigValue) -> Bool {
        if let s = value.string { return s.contains("{{") || s.contains("{%") }
        if let o = value.object {
            if ["choose","if","repeat","parallel","sequence","wait_for_trigger","conditions"].contains(where: { o[$0] != nil }) { return true }
            return o.values.contains(where: hasComplexValue)
        }
        return value.array?.contains(where: hasComplexValue) ?? false
    }

    /// Adopt a verified server write while retaining canvas positions and block identities.
    public static func rebased(_ source: AutomationGraph, on raw: ConfigValue, entityID: String, server: String) throws -> AutomationGraph {
        var graph = source
        if FlowCompiler.isBranched(graph) || graph.importContext?.graphCompiled == true {
            let previous = graph.importContext
            for i in graph.blocks.indices {
                var payload = FlowCompiler.payload(graph.blocks[i], context: previous)
                if previous == nil, graph.blocks[i].kind == .haTrigger, payload.object?["id"] == nil, !graph.blocks[i].flag("manualStart") {
                    payload = payload.setting("id", to: .string(graph.blocks[i].id.uuidString.lowercased()))
                }
                graph.blocks[i].options["configuration"] = payload
                graph.blocks[i].negated = false
            }
            graph.importContext = .init(entityID: entityID, server: server, original: raw,
                triggerIDs: (previous?.triggerIDs ?? []).filter { id in graph.blocks.contains { $0.id == id } } + graph.blocks.filter { $0.kind == .haTrigger && !(previous?.triggerIDs.contains($0.id) ?? false) }.map(\.id),
                conditionIDs: graph.blocks.filter { $0.text("importSection") == "conditions" }.map(\.id),
                actionIDs: graph.blocks.filter { $0.kind != .haTrigger && $0.text("importSection") != "conditions" }.map(\.id),
                originalTitles: Dictionary(uniqueKeysWithValues: graph.blocks.map { ($0.id.uuidString,$0.title) }))
            graph.importContext?.graphCompiled = true
            return graph
        }
        if raw.object?["use_blueprint"] != nil {
            guard graph.blocks.count == 1 else { throw CompilationError(diagnostics: [.init("Blueprint-Zuordnung ist nicht eindeutig.")]) }
            graph.blocks[0].options["configuration"] = raw
        } else {
            let previous = graph.importContext
            let orderedTriggers = (previous?.triggerIDs ?? []).compactMap { id in graph.blocks.first { $0.id == id } } + graph.blocks.filter { $0.kind == .haTrigger && !(previous?.triggerIDs.contains($0.id) ?? false) }
            guard let root = graph.wires.first(where: { $0.source == orderedTriggers.first?.id })?.target else { throw CompilationError(diagnostics: [.init("Der übertragene Ablauf ist nicht zugeordnet.")]) }
            var chain: [Block] = [], current: UUID? = root, seen = Set<UUID>()
            while let id = current, seen.insert(id).inserted, let b = graph.blocks.first(where: { $0.id == id }) { chain.append(b); current = graph.wires.first { $0.source == id }?.target }
            let sections: [([Block],[ConfigValue])] = [
                (orderedTriggers.filter { !$0.flag("manualStart") }, items(raw, plural: "triggers", singular: "trigger")),
                (chain.filter { $0.text("importSection") == "conditions" }, items(raw, plural: "conditions", singular: "condition")),
                (chain.filter { $0.text("importSection") != "conditions" }, items(raw, plural: "actions", singular: "action"))]
            for (blocks, values) in sections {
                guard blocks.count == values.count else { throw CompilationError(diagnostics: [.init("Die Serverfassung hat eine andere Blockstruktur.")]) }
                for (block,value) in zip(blocks,values) {
                    let i = graph.blocks.firstIndex { $0.id == block.id }!
                    graph.blocks[i].options["configuration"] = value; graph.blocks[i].negated = false
                }
            }
        }
        graph.title = raw.object?["alias"]?.string ?? graph.title
        graph.importContext = .init(entityID: entityID, server: server, original: raw,
            triggerIDs: (source.importContext?.triggerIDs ?? []).filter { id in graph.blocks.contains { $0.id == id && $0.kind == .haTrigger } } + graph.blocks.filter { $0.kind == .haTrigger && !(source.importContext?.triggerIDs.contains($0.id) ?? false) }.map(\.id),
            conditionIDs: graph.blocks.filter { $0.text("importSection") == "conditions" }.map(\.id),
            actionIDs: graph.blocks.filter { $0.kind != .haTrigger && $0.text("importSection") != "conditions" }.map(\.id),
            originalTitles: Dictionary(uniqueKeysWithValues: graph.blocks.map { ($0.id.uuidString,$0.title) }))
        return graph
    }

    /// Preserve top-level evaluation timing, implicit trigger IDs, disabled flags and untouched keys.
    public static func export(_ graph: AutomationGraph, context: ImportContext) throws -> ConfigValue {
        let issues = GraphValidator.validate(graph)
        guard issues.isEmpty else { throw CompilationError(diagnostics: issues) }
        guard context.original.object != nil else { throw CompilationError(diagnostics: [.init("Die ursprüngliche Importkonfiguration ist beschädigt.")]) }
        if context.original.object?["use_blueprint"] != nil {
            var value = graph.blocks[0].configuration
            if graph.title != (context.original.object?["alias"]?.string ?? context.entityID) { value = value.setting("alias", to: .string(graph.title)) }
            return value
        }
        if FlowCompiler.isBranched(graph) || context.graphCompiled == true { return try FlowCompiler.configuration(graph) }
        let index = Dictionary(uniqueKeysWithValues: graph.blocks.map { ($0.id, $0) })
        let triggers = context.triggerIDs.compactMap { index[$0] } + graph.blocks.filter { $0.kind == .haTrigger && !context.triggerIDs.contains($0.id) }
        guard let rootID = graph.wires.first(where: { $0.source == triggers.first?.id })?.target,
              triggers.allSatisfy({ t in graph.wires.first { $0.source == t.id }?.target == rootID }) else {
            throw CompilationError(diagnostics: [.init("Eine importierte Automation benötigt einen gemeinsamen Ablauf. Für getrennte Abläufe ein neues Projekt erstellen.")])
        }
        var chain: [Block] = [], current: UUID? = rootID
        while let id = current, let b = index[id] { chain.append(b); current = graph.wires.first { $0.source == id }?.target }
        var sawAction = false
        for b in chain {
            if b.text("importSection") == "conditions" {
                if sawAction || b.kind != .haCondition { throw CompilationError(diagnostics: [.init("Globale Bedingungen müssen vor den Aktionen bleiben.", blockID: b.id)]) }
            } else { sawAction = true }
        }
        func payload(_ b: Block) -> ConfigValue {
            var value = b.configuration
            if b.negated { value = .object(["condition": .string("not"), "conditions": .array([value])]) }
            if b.title != context.originalTitles[b.id.uuidString] {
                if value.array != nil { value = .object(["condition": .string("and"), "conditions": value]) }
                else if value.string != nil || value.bool != nil { value = .object(["condition": .string("template"), "value_template": value]) }
                value = value.setting("alias", to: .string(b.title))
            }
            return value
        }
        var config = context.original.object!
        func replace(_ plural: String, _ singular: String, _ blocks: [Block]) {
            let key = config[plural] != nil ? plural : config[singular] != nil ? singular : plural
            let values = blocks.map(payload)
            if values.isEmpty && (config[key] == nil || config[key] == .null) { return }
            config[key] = config[key]?.array == nil && values.count == 1 ? values[0] : .array(values)
        }
        replace("triggers", "trigger", triggers.filter { !$0.flag("manualStart") })
        replace("conditions", "condition", chain.filter { $0.text("importSection") == "conditions" })
        replace("actions", "action", chain.filter { $0.text("importSection") != "conditions" })
        if graph.title != (context.original.object?["alias"]?.string ?? context.entityID) { config["alias"] = .string(graph.title) }
        return .object(config)
    }
}
