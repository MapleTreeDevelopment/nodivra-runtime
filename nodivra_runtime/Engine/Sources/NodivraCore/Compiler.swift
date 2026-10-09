import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct PlannedHelper: Identifiable, Sendable {
    public let requirement: HelperRequirement
    public let entityID: String
    public let configuration: ConfigValue
    public let blockID: UUID
    public var id: UUID { requirement.key }
}
public struct OutputRule: Sendable {
    public let blockID: UUID
    public let expression: BooleanExpression
    public let entityID: String
    public let behavior: String
}
public struct RuntimeRule: Sendable {
    public let blockID: UUID
    public let kind: BlockKind
    public let inputs: [BooleanExpression]
    public let signalEntity: String
    public let timerEntity: String?
    public let duration: Double
    public let retrigger: Bool
}
public struct AutomationPlan: Sendable {
    public let id: UUID
    public let title: String
    public let blockExpressions: [UUID: BooleanExpression]
    public let outputs: [OutputRule]
    public let runtimeRules: [RuntimeRule]
    public let helpers: [PlannedHelper]
    public let automations: [ConfigValue]
    public let inputs: [String]
    public let inputBlocks: [String: Block]
    public let simulationSupported: Bool
    public var actionRules: [ActionRule] = []
    public var simulationNotes: [String] = []
    public var expression: BooleanExpression { outputs.first?.expression ?? .constant(false) }
    public var outputEntity: String { outputs.first?.entityID ?? "" }
    public func inputsAvailable(_ states: [String: String]) -> Bool { expression.available(states) }
    public var availabilityTemplate: String { "{{ \(expression.availability) }}" }
    public var yaml: String {
        if helpers.isEmpty { return (automations.count == 1 ? automations[0] : array(automations)).yaml }
        return package.yaml
    }
    public var package: ConfigValue {
        var result: [String: ConfigValue] = ["automation": array(automations)]
        for helper in helpers {
            let domain = helper.requirement.kind.rawValue
            let key = String(helper.entityID.split(separator: ".", maxSplits: 1)[1])
            var objects = result[domain]?.object ?? [:]; objects[key] = helper.configuration; result[domain] = object(objects)
        }
        return object(result)
    }
}

public enum GraphCompiler {
    public static func compile(_ graph: AutomationGraph, helperBindings: [UUID: String] = [:]) throws -> AutomationPlan {
        let issues = GraphValidator.validate(graph)
        guard issues.isEmpty else { throw CompilationError(diagnostics: issues) }
        if graph.isFlow { return try compileFlow(graph) }
        let index = Dictionary(uniqueKeysWithValues: graph.blocks.map { ($0.id, $0) })
        var expressions: [UUID: BooleanExpression] = [:], runtime: [RuntimeRule] = [], helpers: [PlannedHelper] = []
        var inputs: [String: Block] = [:], automations: [ConfigValue] = []
        var actionRules: [ActionRule] = [], simulationNotes: [String] = []
        var nativeConditions: [(Block, ConfigValue, String)] = []
        func nativeCondition(_ block: Block, _ config: ConfigValue) throws -> BooleanExpression {
            if let value = SignalBridge.expression(config) {
                for entity in value.dependencies {
                    if entity == "sun.sun" {
                        inputs[entity] = Block(kind: .stateMatch, title: "Sonnenstand · above_horizon / below_horizon", entityID: entity)
                    } else if inputs[entity] == nil { inputs[entity] = Block(kind: ["binary_sensor", "switch", "input_boolean", "light", "fan"].contains(String(entity.split(separator: ".")[0])) ? .state : .stateMatch, title: block.title, entityID: entity) }
                }
                return value
            }
            let entity = try helper(block, .boolean, "condition")
            nativeConditions.append((block, config, entity))
            inputs[entity] = Block(kind: .state, title: block.title + " · Ergebnis vorgeben", entityID: entity)
            simulationNotes.append(block.title + ": Die native HA-Bedingung wird in der Simulation manuell vorgegeben; Home Assistant wertet sie beim Betrieb vollständig aus.")
            return .entity(entity)
        }
        func helper(_ block: Block, _ kind: HelperKind, _ purpose: String) throws -> String {
            let digest = Array(SHA256.hash(data: Data("\(graph.id):\(block.id):\(purpose)".utf8)))
            let key = UUID(uuid: (digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15]))
            let slug = "nodivra_" + graph.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12) + "_" + block.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12) + "_" + purpose
            let entity = helperBindings[key] ?? "\(kind.rawValue).\(slug.lowercased())"
            guard entity.range(of: "^\(kind.rawValue)\\.[a-z0-9_]+$", options: .regularExpression) != nil else { throw CompilationError(diagnostics: [.init("Ungültige Helferzuordnung.", blockID: block.id)]) }
            let name = "\(graph.title) · \(block.title)" + (kind == .timer ? " · Zeit" : "")
            let config: ConfigValue = kind == .number ? object(["name": str(name), "min": .number(0), "max": .number(500), "step": .number(1), "initial": .number(0)]) : kind == .timer ? object(["name": str(name), "duration": object(["seconds": .number(block.duration)]), "restore": .bool(false)]) : object(["name": str(name), "initial": .bool(false)])
            helpers.append(.init(requirement: .init(key: key, kind: kind, name: name), entityID: entity, configuration: config, blockID: block.id))
            return entity
        }
        func expression(_ id: UUID) throws -> BooleanExpression {
            if let cached = expressions[id] { return cached }
            let b = index[id]!
            func input(_ pin: Int) throws -> BooleanExpression {
                let sources = graph.wires.filter { $0.target == id && $0.input == pin }
                let values = try sources.map { try expression($0.source) }
                let expr = values.dropFirst().reduce(values.first ?? .constant(true)) { .or($0, $1) }
                return b.negatedInputs.contains(pin) ? .not(expr) : expr
            }
            var value: BooleanExpression
            switch b.kind {
            case .digitalInput, .analogInput, .digitalOutput, .analogOutput, .marker, .analogMarker, .markerContact, .analogContact, .analogCompare:
                throw CompilationError(diagnostics: [.init("SPS-Bausteine benötigen Nodivra Runtime 0.2 oder neuer.", blockID: b.id)])
            case .state: value = .entity(b.entityID); inputs[b.entityID] = b
            case .stateMatch: value = .matches(b.entityID, b.text("expected", "on")); inputs[b.entityID] = b
            case .numeric: value = .numeric(b.entityID, b.text("comparison", ">"), b.number("threshold", 20)); inputs[b.entityID] = b
            case .timeWindow: value = .timeWindow(TimeWindow(block: b))
            case .constant: value = .constant(b.flag("value", true))
            case .button:
                let entity = b.managedButton ? try helper(b, .boolean, "button") : b.entityID
                value = .entity(entity); inputs[entity] = b
                if b.momentary {
                    let rule = RuntimeRule(blockID: b.id, kind: .button, inputs: [.entity(entity)], signalEntity: entity, timerEntity: nil, duration: b.duration, retrigger: b.text("retrigger", "restart") == "restart")
                    runtime.append(rule); automations.append(buttonAutomation(graph, b, rule))
                }
            case .and: value = try .and(input(0), input(1))
            case .or: value = try .or(input(0), input(1))
            case .xor: value = try .xor(input(0), input(1))
            case .not: value = try .not(input(0))
            case .onDelay, .offDelay, .pulse, .latch:
                let source = try (0..<b.kind.inputCount).map { try input($0) }
                let signal = try helper(b, .boolean, "signal")
                let timer = b.kind == .latch ? nil : try helper(b, .timer, "timer")
                let rule = RuntimeRule(blockID: b.id, kind: b.kind, inputs: source, signalEntity: signal, timerEntity: timer, duration: b.duration, retrigger: b.text("retrigger", "restart") == "restart")
                runtime.append(rule); automations.append(memoryAutomation(graph, b, rule)); value = .entity(signal)
            case .output: value = try input(0)
            case .haTrigger:
                if b.configuration.object?["enabled"]?.bool == false { value = .constant(false) }
                else if b.text("signalBehavior", "event") == "state" {
                    value = try nativeCondition(b, SignalBridge.stateCondition(b)!)
                } else {
                    let entity = try helper(b, .boolean, "event")
                    value = .entity(entity)
                    inputs[entity] = Block(id: b.id, kind: .button, title: b.title + " · Ereignis auslösen", entityID: entity, options: ["duration": .number(b.number("signalDuration", 0.5))])
                    runtime.append(.init(blockID: b.id, kind: .button, inputs: [.entity(entity)], signalEntity: entity, timerEntity: nil, duration: b.number("signalDuration", 0.5), retrigger: true))
                    automations.append(signalEventAutomation(graph, b, entity))
                }
            case .haCondition:
                let condition = try nativeCondition(b, b.configuration)
                value = graph.wires.contains { $0.target == id } ? try .and(input(0), condition) : condition
            case .haAction:
                let source = try input(0)
                guard !source.dependencies.isEmpty || source.usesClock else { throw CompilationError(diagnostics: [.init("Diese Aktion benötigt einen veränderlichen Eingang oder einen Ereignisauslöser.", blockID: b.id)]) }
                let completion = graph.wires.contains { $0.source == id } ? try helper(b, .boolean, "completed") : nil
                actionRules.append(.init(blockID: b.id, expression: source, configuration: b.configuration, offConfiguration: SignalBridge.offAction(b), behavior: SignalBridge.resolvedActionBehavior(b, in: graph), completionEntity: completion))
                value = completion.map { .entity($0) } ?? source
            }
            if b.negated { value = .not(value) }
            expressions[id] = value; return value
        }
        var outputs: [OutputRule] = []
        for block in graph.blocks where block.kind == .output {
            let expr = try expression(block.id)
            guard !expr.dependencies.isEmpty || expr.usesClock else { throw CompilationError(diagnostics: [.init("Eine reine Konstante hat keinen auslösenden Zustandswechsel.", blockID: block.id)]) }
            let output = OutputRule(blockID: block.id, expression: expr, entityID: block.entityID, behavior: block.text("behavior", "follow"))
            outputs.append(output); automations.append(outputAutomation(graph, block, output))
        }
        for block in graph.blocks where block.kind == .haAction { _ = try expression(block.id) }
        for key in Set(actionRules.filter { $0.behavior == "follow" }.map(\.groupKey)).sorted() {
            let indices = actionRules.indices.filter { actionRules[$0].groupKey == key }
            if indices.count > 1 {
                let first = graph.blocks.first { $0.id == actionRules[indices[0]].blockID }!
                let selected = try helper(first, .number, "active_branch")
                for (order, i) in indices.enumerated() { actionRules[i].selectionEntity = selected; actionRules[i].selectionIndex = order + 1 }
            }
        }
        for (block, config, entity) in nativeConditions {
            automations.append(conditionAutomation(graph, block, config, entity, owned: helpers.map(\.entityID)))
        }
        automations += actionAutomations(graph, actionRules)
        guard Set(helpers.map(\.entityID)).count == helpers.count else { throw CompilationError(diagnostics: [.init("Helferzuordnungen verwenden dieselbe Entität mehrfach.")]) }
        let externalEntities = Set(inputs.keys.filter { key in !helpers.contains { $0.entityID == key } }).union(Set(graph.blocks.filter { ($0.kind.isEntityInput && !$0.managedButton) || $0.kind == .output }.map(\.entityID)))
        let nativeEntities = graph.blocks.filter { $0.kind.isFlow }.reduce(into: Set<String>()) { $0.formUnion(SignalBridge.entityReferences($1.configuration)) }
        guard externalEntities.union(nativeEntities).isDisjoint(with: helpers.map(\.entityID)) else { throw CompilationError(diagnostics: [.init("Eine interne Helferzuordnung überschneidet sich mit einem gewählten Ein- oder Ausgang.")]) }
        let unsupported = actionRules.filter { rule in
            if rule.behavior == "follow" { return [rule.configuration, rule.offConfiguration ?? .null].contains { ($0.object?["action"] ?? $0.object?["service"])?.string == nil } }
            return !ActionSimulation.supports(rule.configuration)
        }
        let simulationSupported = unsupported.isEmpty
        for rule in unsupported {
            let name = graph.blocks.first { $0.id == rule.blockID }?.title ?? "Aktion"
            simulationNotes.append("\(name): Dieser Ablauf kann noch nicht lokal simuliert werden. Unterstützt sind Dienstaufrufe und Warten mit einer festen Dauer; dynamische Wartebedingungen, Templates und verschachtelte Abläufe benötigen Home Assistant.")
        }
        return .init(id: graph.id, title: graph.title, blockExpressions: expressions, outputs: outputs, runtimeRules: runtime, helpers: helpers, automations: automations, inputs: inputs.keys.sorted(), inputBlocks: inputs, simulationSupported: simulationSupported, actionRules: actionRules, simulationNotes: simulationNotes)
    }
    static func automation(_ graph: AutomationGraph, _ block: Block, triggers: [ConfigValue], conditions: [ConfigValue] = [], actions: [ConfigValue], mode: String = "restart") -> ConfigValue {
        object(["id": str("nodivra_\(graph.id.uuidString.lowercased())_\(block.id.uuidString.lowercased())"), "alias": str(graph.title + " · " + block.title), "description": str(block.notes.isEmpty ? "Created with Nodivra" : block.notes), "triggers": array(triggers), "conditions": array(conditions), "actions": array(actions), "mode": str(mode)])
    }
    static func call(_ action: String, _ entity: String, _ data: [String: ConfigValue] = [:]) -> ConfigValue {
        var d: [String: ConfigValue] = ["action": str(action), "target": object(["entity_id": str(entity)])]
        if !data.isEmpty { d["data"] = object(data) }; return object(d)
    }
    static func set(_ entity: String, _ value: Bool) -> ConfigValue { call("\(entity.split(separator: ".")[0]).turn_\(value ? "on" : "off")", entity) }
    static func condition(_ template: String) -> ConfigValue { object(["condition": str("template"), "value_template": str("{{ \(template) }}")]) }
    static func trigger(_ template: String, _ id: String) -> ConfigValue { object(["trigger": str("template"), "value_template": str("{{ \(template) }}"), "id": str(id)]) }
    static func stateTrigger(_ entities: Set<String>) -> ConfigValue { object(["trigger": str("state"), "entity_id": array(entities.sorted().map(str)), "to": .null]) }
    static func changeTriggers(_ expression: BooleanExpression) -> [ConfigValue] {
        var triggers: [ConfigValue] = expression.dependencies.isEmpty ? [] : [stateTrigger(expression.dependencies)]
        // now() expressions update each minute in HA, also across DST changes.
        if expression.usesClock { triggers.append(object(["trigger": str("time_pattern"), "minutes": str("*"), "seconds": str("0")])) }
        return triggers
    }
    static func branch(_ id: String, _ actions: [ConfigValue], extra: [ConfigValue] = []) -> ConfigValue {
        object(["conditions": array([object(["condition": str("trigger"), "id": str(id)])] + extra), "sequence": array(actions)])
    }
    static func buttonAutomation(_ graph: AutomationGraph, _ block: Block, _ rule: RuntimeRule) -> ConfigValue {
        automation(graph, block, triggers: [object(["trigger": str("state"), "entity_id": str(rule.signalEntity), "to": str("on")])], actions: [object(["delay": object(["seconds": .number(rule.duration)])]), set(rule.signalEntity, false)], mode: rule.retrigger ? "restart" : "single")
    }
    static func outputAutomation(_ graph: AutomationGraph, _ block: Block, _ rule: OutputRule) -> ConfigValue {
        let e = rule.expression
        let actions: [ConfigValue]
        if rule.behavior == "follow" {
            actions = [object(["choose": array([object(["conditions": array([condition(e.template)]), "sequence": array([set(rule.entityID, true)])])]), "default": array([set(rule.entityID, false)])])]
        } else {
            let service = rule.behavior == "off" ? "turn_off" : rule.behavior == "toggle" ? "toggle" : "turn_on"
            actions = [condition(e.template), call("\(rule.entityID.split(separator: ".")[0]).\(service)", rule.entityID)]
        }
        let triggers = e.usesClock
            ? [trigger("(\(e.availability)) and (\(e.template))", "on"), trigger("(\(e.availability)) and not (\(e.template))", "off")]
            : changeTriggers(e)
        return automation(graph, block, triggers: triggers, conditions: [condition(e.availability)], actions: actions)
    }
    static func memoryAutomation(_ graph: AutomationGraph, _ block: Block, _ r: RuntimeRule) -> ConfigValue {
        let e = r.inputs[0]
        if r.kind == .latch {
            let reset = r.inputs[1]
            let choose = object(["choose": array([
                object(["conditions": array([condition(reset.template)]), "sequence": array([set(r.signalEntity, false)])]),
                object(["conditions": array([condition(e.template)]), "sequence": array([set(r.signalEntity, true)])])
            ])])
            return automation(graph, block, triggers: changeTriggers(.or(e, reset)), conditions: [condition("\(e.availability) and \(reset.availability)")], actions: [choose])
        }
        let timer = r.timerEntity!
        let start = call("timer.start", timer, ["duration": object(["seconds": .number(r.duration)])])
        let cancel = call("timer.cancel", timer)
        var triggers = [trigger("(\(e.availability)) and (\(e.template))", "on")]
        if r.kind != .pulse { triggers.append(trigger("(\(e.availability)) and not (\(e.template))", "off")) }
        triggers.append(object(["trigger": str("event"), "event_type": str("timer.finished"), "event_data": object(["entity_id": str(timer)]), "id": str("elapsed")]))
        var branches: [ConfigValue] = []
        switch r.kind {
        case .onDelay:
            branches = [branch("on", [start]), branch("off", [cancel, set(r.signalEntity, false)]), branch("elapsed", [set(r.signalEntity, true)], extra: [condition("(\(e.availability)) and (\(e.template))")])]
        case .offDelay:
            branches = [branch("on", [cancel, set(r.signalEntity, true)]), branch("off", [start]), branch("elapsed", [set(r.signalEntity, false)], extra: [condition("(\(e.availability)) and not (\(e.template))")])]
        default:
            branches = [branch("on", [start, set(r.signalEntity, true)], extra: r.retrigger ? [] : [condition("is_state('\(r.signalEntity)', 'off')")]), branch("elapsed", [set(r.signalEntity, false)])]
        }
        return automation(graph, block, triggers: triggers, actions: [object(["choose": array(branches)])])
    }
    static func compileFlow(_ graph: AutomationGraph) throws -> AutomationPlan {
        if let context = graph.importContext {
            return .init(id: graph.id, title: graph.title, blockExpressions: [:], outputs: [], runtimeRules: [], helpers: [], automations: [try AutomationImporter.export(graph, context: context)], inputs: [], inputBlocks: [:], simulationSupported: false)
        }
        return .init(id: graph.id, title: graph.title, blockExpressions: [:], outputs: [], runtimeRules: [], helpers: [], automations: [try FlowCompiler.configuration(graph)], inputs: [], inputBlocks: [:], simulationSupported: false)
    }
}
