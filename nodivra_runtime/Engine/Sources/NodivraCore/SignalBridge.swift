import Foundation

public struct ActionRule: Sendable {
    public let blockID: UUID
    public let expression: BooleanExpression
    public let configuration: ConfigValue
    public let offConfiguration: ConfigValue?
    public let behavior: String
    public let completionEntity: String?
    public var selectionEntity: String? = nil
    public var selectionIndex: Int = 0
    public var groupKey: String { behavior == "follow" ? SignalBridge.targetKey(configuration) : blockID.uuidString }
}

/// Adapts HA's event/condition/action vocabulary to explicit boolean signals.
public enum SignalBridge {
    public static func stateCondition(_ block: Block) -> ConfigValue? {
        let c = block.configuration.object ?? [:]
        let type = HAConfiguration.type(block.configuration, role: .haTrigger)
        switch type {
        case "sun":
            guard let event = c["event"]?.string, ["sunset", "sunrise"].contains(event) else { return nil }
            return object(["condition": str("sun"), "after": str(event), "before": str(event == "sunset" ? "sunrise" : "sunset"), "after_offset": c["offset"] ?? str("00:00:00")])
        case "state":
            guard let to = c["to"], to.string != nil, let entities = c["entity_id"] else { return nil }
            var result = ["condition": str("state"), "entity_id": entities, "state": to]
            for key in ["attribute", "for"] { result[key] = c[key] }
            return object(result)
        case "numeric_state":
            guard c["entity_id"] != nil, c["for"] == nil else { return nil }
            var result = c; result.removeValue(forKey: "trigger"); result.removeValue(forKey: "platform")
            for key in ["id", "alias", "enabled"] { result.removeValue(forKey: key) }
            result["condition"] = str("numeric_state"); return object(result)
        case "time":
            guard let at = c["at"]?.string, at.range(of: "^[0-2][0-9]:[0-5][0-9]:00$", options: .regularExpression) != nil else { return nil }
            return object(["condition": str("time"), "after": str(at)])
        case "template":
            guard c["for"] == nil, let template = c["value_template"] else { return nil }
            return object(["condition": str("template"), "value_template": template])
        default: return nil
        }
    }
    public static func offAction(_ block: Block) -> ConfigValue? {
        if let custom = block.options["offConfiguration"], custom.object?.isEmpty == false { return custom }
        let c = block.configuration.object ?? [:]
        let action = (c["action"] ?? c["service"])?.string ?? ""
        guard c["enabled"]?.bool != false else { return nil }
        guard ["light.turn_on", "switch.turn_on", "fan.turn_on", "input_boolean.turn_on"].contains(action), c["target"] != nil else { return nil }
        return object(["action": str(action.replacingOccurrences(of: ".turn_on", with: ".turn_off")), "target": c["target"]!])
    }
    public static func actionBehavior(_ block: Block) -> String { block.text("actionBehavior").isEmpty ? (offAction(block) == nil ? "rising" : "follow") : block.text("actionBehavior") }
    public static func resolvedActionBehavior(_ block: Block, in graph: AutomationGraph) -> String {
        if !block.text("actionBehavior").isEmpty { return block.text("actionBehavior") }
        func event(_ id: UUID, seen: Set<UUID> = []) -> Bool {
            guard !seen.contains(id), let b = graph.blocks.first(where: { $0.id == id }) else { return false }
            if b.kind == .haTrigger { return b.text("signalBehavior", "event") == "event" }
            if b.kind == .haAction || (b.kind == .button && b.momentary) { return true }
            if b.kind.isMemory || b.kind.isMarker || b.kind.isContact { return false }
            return graph.wires.filter { $0.target == id }.contains { event($0.source, seen: seen.union([id])) }
        }
        if graph.wires.filter({ $0.target == block.id }).contains(where: { event($0.source) }) { return "rising" }
        return actionBehavior(block)
    }
    public static func targetKey(_ config: ConfigValue) -> String {
        let c = config.object ?? [:]
        let service = (c["action"] ?? c["service"])?.string ?? ""
        func canonical(_ value: ConfigValue) -> ConfigValue {
            if let a = value.array { return array(a.map(canonical).sorted { $0.json < $1.json }) }
            if let o = value.object { return object(o.mapValues(canonical)) }
            return value
        }
        return service + ":" + canonical(c["target"] ?? .null).json
    }
    public static func strings(_ value: ConfigValue?) -> [String] {
        if let s = value?.string { return [s] }; return value?.array?.compactMap(\.string) ?? []
    }
    /// Only lower configurations whose complete semantics are represented locally.
    static func expression(_ config: ConfigValue) -> BooleanExpression? {
        if let b = config.bool { return .constant(b) }
        if let a = config.array { return combine(a, type: "and") }
        guard let c = config.object else { return nil }
        let type = c["condition"]?.string ?? ["and", "or", "not"].first { c[$0] != nil } ?? ""
        let keys = Set(c.keys).subtracting(["condition", "alias"])
        switch type {
        case "state":
            guard keys.isSubset(of: ["entity_id", "state"]), let expected = c["state"]?.string else { return nil }
            let ids = strings(c["entity_id"]); guard !ids.isEmpty, ids.allSatisfy({ $0.range(of: "^[a-z_]+\\.[a-z0-9_]+$", options: .regularExpression) != nil }) else { return nil }
            return ids.map { BooleanExpression.matches($0, expected) }.reduce(.constant(true)) { .and($0, $1) }
        case "numeric_state":
            guard keys.isSubset(of: ["entity_id", "above", "below"]), c["above"] == nil || c["above"]?.number?.isFinite == true,
                  c["below"] == nil || c["below"]?.number?.isFinite == true else { return nil }
            let ids = strings(c["entity_id"]); guard !ids.isEmpty, ids.allSatisfy({ $0.range(of: "^[a-z_]+\\.[a-z0-9_]+$", options: .regularExpression) != nil }) else { return nil }
            return ids.reduce(.constant(true)) { value, id in
                var result = value
                if let n = c["above"]?.number { result = .and(result, .numeric(id, ">", n)) }
                if let n = c["below"]?.number { result = .and(result, .numeric(id, "<", n)) }
                return result
            }
        case "time":
            guard keys.isSubset(of: ["after", "before", "weekday"]), c["after"] != nil || c["before"] != nil || c["weekday"] != nil else { return nil }
            var options: [String: ConfigValue] = ["mode": str(c["after"] != nil ? (c["before"] != nil ? "between" : "after") : (c["before"] != nil ? "before" : "allDay"))]
            options["after"] = c["after"]; options["before"] = c["before"]
            if c["weekday"] != nil { options["weekdays"] = array(strings(c["weekday"]).map(str)) }
            let window = TimeWindow(block: .init(kind: .timeWindow, title: "Zeit", options: options))
            return window.valid ? .timeWindow(window) : nil
        case "sun":
            guard keys.isSubset(of: ["after", "before", "after_offset", "before_offset"]),
                  ["after_offset", "before_offset"].allSatisfy({ c[$0] == nil || c[$0]?.string == "00:00:00" || c[$0]?.number == 0 }) else { return nil }
            if c["after"]?.string == "sunset", c["before"]?.string == "sunrise" { return .matches("sun.sun", "below_horizon") }
            if c["after"]?.string == "sunrise", c["before"]?.string == "sunset" { return .matches("sun.sun", "above_horizon") }
            return nil
        case "and", "or", "not":
            guard keys.isSubset(of: ["conditions", type]), let a = (c["conditions"] ?? c[type])?.array else { return nil }
            return combine(a, type: type)
        default: return nil
        }
    }
    private static func combine(_ values: [ConfigValue], type: String) -> BooleanExpression? {
        let expressions = values.compactMap(expression)
        guard expressions.count == values.count else { return nil }
        if type == "or" { return expressions.reduce(.constant(false)) { .or($0, $1) } }
        if type == "not" { return expressions.reduce(.constant(true)) { .and($0, .not($1)) } }
        return expressions.reduce(.constant(true)) { .and($0, $1) }
    }
    static func entityReferences(_ value: ConfigValue) -> Set<String> {
        if let array = value.array { return array.reduce(into: Set<String>()) { $0.formUnion(entityReferences($1)) } }
        guard let object = value.object else { return [] }
        return object.reduce(into: Set<String>()) { result, pair in
            if pair.key == "entity_id" { result.formUnion(strings(pair.value)) }
            else { result.formUnion(entityReferences(pair.value)) }
        }
    }
    static func diagnostics(_ graph: AutomationGraph) -> [Diagnostic] {
        var result: [Diagnostic] = []
        let native = graph.blocks.filter { $0.kind.isFlow }
        if let original = graph.importContext?.original.object, !native.isEmpty,
           ["variables", "trigger_variables"].contains(where: { original[$0]?.object?.isEmpty == false }) {
            result.append(.init("Dieser Import verwendet gemeinsame Variablen. Vor dem Aufteilen in Signale müssen sie in den jeweiligen Aktionen definiert werden."))
        }
        for b in native {
            func issue(_ text: String) { result.append(.init(text, blockID: b.id)) }
            if b.flag("manualStart") { issue("Ersetze den manuellen Start durch einen Ereignisauslöser oder einen virtuellen Taster.") }
            let scoped = b.configuration.json.range(of: #"(?<![\w.])(trigger|this)\s*[.\[]"#, options: .regularExpression) != nil
            let freeWait = b.configuration.json.contains("wait.") && !b.configuration.json.contains("wait_for_trigger") && !b.configuration.json.contains("wait_template")
            let freeRepeat = b.configuration.json.contains("repeat.") && !b.configuration.json.contains("\"repeat\"")
            if scoped || freeWait || freeRepeat || b.configuration.object?["condition"]?.string == "trigger" {
                issue("Dieser Block benötigt den ursprünglichen Ablaufkontext (z. B. trigger). Verwende dafür einen zusammenhängenden HA-Ablauf; ein Logiksignal überträgt nur Ein/Aus.")
            }
            if b.kind == .haTrigger {
                if !["event", "state"].contains(b.text("signalBehavior", "event")) { issue("Wähle Ereignisimpuls oder dauerhaften Zustand.") }
                if b.text("signalBehavior") == "state" && stateCondition(b) == nil { issue("Dieser Auslöser beschreibt kein dauerhaftes Zeitfenster oder einen Zustand. Verwende den Ereignisimpuls oder einen Bedingungsblock.") }
                if !b.number("signalDuration", 0.5).isFinite || !(0.1...86400).contains(b.number("signalDuration", 0.5)) { issue("Die Impulsdauer muss zwischen 0,1 Sekunden und 24 Stunden liegen.") }
            }
            if b.kind == .haAction {
                let behavior = actionBehavior(b)
                if !["rising", "falling", "follow"].contains(behavior) { issue("Wähle ein gültiges Aktionsverhalten.") }
                if behavior == "follow" && offAction(b) == nil { issue("Für Ein/Aus folgen benötigt diese Aktion eine ausdrücklich festgelegte Aus-Aktion.") }
                if (b.configuration.object?["variables"] != nil || b.configuration.object?["response_variable"] != nil), graph.wires.contains(where: { $0.source == b.id }) { issue("Variablen gelten innerhalb einer Aktion. Fasse die Schritte, die sie verwenden, in einem Sequenzblock zusammen.") }
            }
        }
        let follow = native.filter { $0.kind == .haAction && resolvedActionBehavior($0, in: graph) == "follow" }
        for group in Dictionary(grouping: follow, by: { targetKey($0.configuration) }).values where group.count > 1 {
            if Set(group.compactMap { offAction($0).map(targetKey) }).count > 1 { result.append(.init("Zweige desselben Ziels benötigen dieselbe Aus-Aktion.", blockID: group[0].id)) }
        }
        return result
    }
}

extension GraphCompiler {
    static func signalEventAutomation(_ graph: AutomationGraph, _ block: Block, _ entity: String) -> ConfigValue {
        let triggers = block.configuration.object?["triggers"]?.array ?? [block.configuration]
        return automation(graph, block, triggers: triggers, actions: [set(entity, false), object(["delay": .number(0.05)]), set(entity, true), object(["delay": .number(block.number("signalDuration", 0.5))]), set(entity, false)])
    }
    static func conditionAutomation(_ graph: AutomationGraph, _ block: Block, _ config: ConfigValue, _ entity: String, owned: [String]) -> ConfigValue {
        // Stop metadata feedback BEFORE an action script starts (starting it changes
        // automation.last_triggered/current and emits another state_changed event).
        let allowed = "trigger.platform != 'event' or (trigger.event.data.entity_id not in " + array(owned.map(str)).json + " and (trigger.event.data.entity_id.split('.')[0] not in ['automation', 'script'] or trigger.event.data.old_state is none or trigger.event.data.new_state is none or trigger.event.data.old_state.state != trigger.event.data.new_state.state))"
        let on = condition("not is_state('\(entity)', 'on')"), off = condition("not is_state('\(entity)', 'off')")
        let changed = object(["condition": str("or"), "conditions": array([
            object(["condition": str("and"), "conditions": array([config, on])]),
            object(["condition": str("and"), "conditions": array([object(["condition": str("not"), "conditions": array([config])]), off])])
        ])])
        let choose = object(["choose": array([object(["conditions": array([config]), "sequence": array([set(entity, true)])])]), "default": array([set(entity, false)])])
        let kind = config.object?["condition"]?.string ?? ""
        let clockSensitive = ["sun", "time"].contains(kind) || config.json.contains("\"for\"")
        let clock: ConfigValue = clockSensitive ? object(["trigger": str("time_pattern"), "seconds": str("/1")]) : object(["trigger": str("time_pattern"), "minutes": str("*"), "seconds": str("0")])
        var triggers = [clock, object(["trigger": str("homeassistant"), "event": str("start")])]
        // Sun and clock conditions do not depend on arbitrary HA state events.
        if kind == "sun" { triggers.append(object(["trigger": str("state"), "entity_id": str("sun.sun")])) }
        else if kind != "time" { triggers.append(object(["trigger": str("event"), "event_type": str("state_changed")])) }
        return automation(graph, block, triggers: triggers, conditions: [condition(allowed), changed], actions: [choose])
    }

    static func actionAutomations(_ graph: AutomationGraph, _ rules: [ActionRule]) -> [ConfigValue] {
        Dictionary(grouping: rules, by: \.groupKey).keys.sorted().map { key in
            let group = rules.filter { $0.groupKey == key }.sorted { $0.selectionIndex < $1.selectionIndex }
            let first = group[0], block = graph.blocks.first { $0.id == first.blockID }!
            func sequence(_ r: ActionRule) -> [ConfigValue] {
                var actions = [r.configuration]
                if let selected = r.selectionEntity { actions.append(call("input_number.set_value", selected, ["value": .number(Double(r.selectionIndex))])) }
                if let entity = r.completionEntity { actions += [set(entity, true), object(["delay": .number(0.1)]), set(entity, false)] }
                return actions
            }
            var triggers: [ConfigValue] = []
            for r in group {
                let e = r.expression
                if r.behavior != "falling" { triggers.append(trigger("(\(e.availability)) and (\(e.template))", "on_\(r.blockID)")) }
                if r.behavior != "rising" { triggers.append(trigger("(\(e.availability)) and not (\(e.template))", "off_\(r.blockID)")) }
            }
            let actions: [ConfigValue]
            if first.behavior == "follow" {
                var choices: [ConfigValue] = []
                if let selected = first.selectionEntity {
                    // The most recently activated branch owns this target until it
                    // expires or another branch activates. Expiring inactive tails do nothing.
                    choices += group.map { r in branch("on_\(r.blockID)", sequence(r), extra: [condition(r.expression.template), condition("states('\(selected)') | int(0) != \(r.selectionIndex)")]) }
                    choices += group.map { r in object(["conditions": array([condition("states('\(selected)') | int(0) == \(r.selectionIndex) and (\(r.expression.template))")]), "sequence": array([object(["stop": str("Aktiver Zweig bleibt unverändert")])])]) }
                }
                choices += group.map { r in object(["conditions": array([condition(r.expression.template)]), "sequence": array(sequence(r))]) }
                var off = [first.offConfiguration!]
                if let selected = first.selectionEntity { off.append(call("input_number.set_value", selected, ["value": .number(0)])) }
                actions = [object(["choose": array(choices), "default": array(off)])]
            } else { actions = sequence(first) }
            let available = group.map { "(\($0.expression.availability))" }.joined(separator: " and ")
            // Queue transitions so a completion pulse is reset even if another edge arrives.
            return automation(graph, block, triggers: triggers, conditions: [condition(available)], actions: actions, mode: "queued")
        }
    }
}
