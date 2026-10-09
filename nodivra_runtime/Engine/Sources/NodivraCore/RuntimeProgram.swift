import Foundation

/// Versioned, portable graph consumed by both the app and the HA OS process.
public struct RuntimePackage: Codable, Equatable, Sendable {
    public var protocolVersion: Int = 1
    public var graph: AutomationGraph
    public var timeZone: String
    public init(graph: AutomationGraph, timeZone: String = TimeZone.current.identifier) { self.graph = graph; self.timeZone = timeZone; protocolVersion = graph.usesActionParameters ? 5 : graph.usesVariableParameters ? 4 : graph.usesExtendedPLC ? 3 : graph.usesPLCCycle ? 2 : 1 }
}
public struct RuntimeIssue: Codable, Identifiable, Equatable, Sendable {
    public var blockID: UUID?
    public var message: String
    public var id: String { "\(blockID?.uuidString ?? "graph"):\(message)" }
    public init(_ message: String, blockID: UUID? = nil) { self.message = message; self.blockID = blockID }
}
public struct RuntimeValidation: Codable, Sendable {
    public var issues: [RuntimeIssue]
    public var inputs: [String]
    public var deviceActions: Int
    public var valid: Bool { issues.isEmpty }
}
public enum RuntimeCompiler {
    public static let version = "0.5.0"
    public static let catalogIDs: Set<String> = Set(["logic.digitalInput", "logic.analogInput", "logic.digitalOutput", "logic.analogOutput", "logic.marker", "logic.analogMarker", "logic.markerContact", "logic.analogContact", "logic.analogCompare", "logic.state", "logic.stateMatch", "logic.numeric", "logic.constant", "logic.timeWindow", "logic.button", "logic.and", "logic.or", "logic.xor", "logic.not", "logic.onDelay", "logic.offDelay", "logic.pulse", "logic.latch", "logic.output", "logic.darkness", "logic.motion", "logic.autoOff", "trigger.state", "trigger.time", "trigger.pattern", "condition.state", "condition.numeric", "condition.time", "action.service", "action.light", "action.delay", "runtime.log"]).union(PLCFunction.allCases.map { "plc." + $0.rawValue })
    public static func validate(_ package: RuntimePackage) -> RuntimeValidation {
        let g = package.graph
        var issues: [RuntimeIssue] = []
        func fail(_ text: String, _ b: Block? = nil) { issues.append(.init(text, blockID: b?.id)) }
        if ![1, 2, 3, 4, 5].contains(package.protocolVersion) || ![2, 3, 4, 5, 6].contains(g.formatVersion) || (g.usesPLCCycle && package.protocolVersion < 2) || (g.usesExtendedPLC && package.protocolVersion < 3) || (g.usesVariableParameters && package.protocolVersion < 4) || (g.usesActionParameters && package.protocolVersion < 5) { fail("Diese Programmversion wird von der Runtime nicht unterstützt.") }
        if TimeZone(identifier: package.timeZone) == nil { fail("Eine gültige Zeitzone ist erforderlich.") }
        if g.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail("Gib der Automation einen Namen.") }
        if g.blocks.isEmpty || g.blocks.count > 150 || g.wires.count > 400 { fail("Ein Programm benötigt 1 bis 150 Bausteine und höchstens 400 Verbindungen.") }
        if g.importContext != nil { fail("Dieser Entwurf enthält einen ursprünglichen HA-Ablauf. Seine globalen Einstellungen müssen vor einer Runtime-Migration ausdrücklich angepasst werden. Der alte Entwurf bleibt erhalten.") }
        guard Set(g.blocks.map(\.id)).count == g.blocks.count, Set(g.wires.map(\.id)).count == g.wires.count else {
            return .init(issues: [.init("Doppelte Baustein- oder Verbindungskennung.")], inputs: [], deviceActions: 0)
        }
        let blocks = Dictionary(uniqueKeysWithValues: g.blocks.map { ($0.id, $0) })
        for w in g.wires {
            guard let a = blocks[w.source], let b = blocks[w.target], a.kind.hasOutput, (w.source != w.target || b.kind.isMarker), (0..<b.inputCount).contains(w.input), (0..<a.outputCount).contains(w.output) else { fail("Eine Verbindung hat keinen gültigen Anschluss."); continue }
            if a.outputType(w.output) != b.inputType(w.input) { fail("Die Datentypen der Anschlüsse passen nicht zusammen. Ein/Aus, Zahlen, Text, Listen und Objekte benötigen jeweils einen passenden Eingang.", b) }
        }
        if ordered(g).count != g.blocks.count { fail("Eine Rückführung benötigt einen Merker. Eine Schleife ohne Zyklusspeicher ist nicht ausführbar.") }
        var inputs = Set<String>(), actions = 0
        for b in g.blocks {
            if let reset = b.options["resettable"], reset.bool == nil { fail("Rücksetzen benötigt Ein oder Aus.", b) }
            if b.kind == .latch && !["reset", "set"].contains(b.text("priority", "reset")) { fail("Wähle Setzen oder Rücksetzen als Vorrang.", b) }
            if b.isGate && g.wires.allSatisfy({ $0.target != b.id }) { fail("Verbinde mindestens einen Eingang.", b) }
            if let count = b.options["inputCount"], !b.configurableInputCount || count.number.map({ !$0.isFinite || $0.rounded() != $0 || !(2...8).contains($0) }) != false { fail("Dieser Baustein unterstützt 2 bis 8 Eingänge.", b) }
            if b.kind == .function {
                if let f = b.function {
                    for parameter in f.parameters {
                        if f == .valueSelect && b.typedSelection && parameter.key != "valueUnit" { continue }
                        let value = b.options[parameter.key] ?? parameter.initial
                        if let range = parameter.range {
                            if value.number.map({ $0.isFinite && range.contains($0) }) != true { fail("\(parameter.label): Wähle einen Wert zwischen \(range.lowerBound) und \(range.upperBound).", b) }
                        } else if value.string == nil || !parameter.choices.isEmpty && !parameter.choices.contains(value.string ?? "") { fail("Wähle einen gültigen Wert für \(parameter.label).", b) }
                    }
                    for key in ["count", "length", "tap", "samples", "startValue"] where b.options[key] != nil { if b.number(key).rounded() != b.number(key) { fail("\(key) benötigt eine ganze Zahl.", b) } }
                    if f == .valueSelect && b.typedSelection {
                        for key in ["defaultValue"] + (1...b.inputCount).map({ "value\($0)" }) {
                            let value = b.selectedValue(key)
                            if !b.selectionType.accepts(value) || value.json.utf8.count > 65536 || b.text("valueUnit") == "integer" && value.number.map({ $0.rounded() == $0 && abs($0) <= 1e9 }) != true { fail("\(key): Wähle einen gültigen Wert vom Typ \(b.selectionType.label).", b) }
                        }
                    }
                    if f == .valueSelect && b.selectionUsesTime {
                        for key in ["defaultValue"] + (1...b.inputCount).map({ "value\($0)" }) {
                            if !(0.1...86400).contains(b.number(key, key == "defaultValue" ? 300 : 120)) { fail("Zeitwerte müssen zwischen 0,1 Sekunden und 24 Stunden liegen.", b) }
                        }
                    }
                    if f == .shiftRegister && b.number("tap", 1) > b.number("length", 8) { fail("Das Ausgangsbit liegt außerhalb des Schieberegisters.", b) }
                    if [.pi, .pwm, .limit].contains(f) && b.number("minimum", 0) >= b.number("maximum", 100) { fail("Minimum muss kleiner als Maximum sein.", b) }
                    if [.staircase, .comfort].contains(f) && b.number("warning", 0) >= b.number("duration", 5) { fail("Die Vorwarnzeit muss kürzer als die Laufzeit sein.", b) }
                    if f == .yearClock {
                        for key in ["start", "end"] {
                            let value = b.text(key, key == "start" ? "01-01" : "12-31")
                            let parts = value.split(separator: "-").compactMap { Int($0) }
                            if parts.count != 2 || parts.count == 2 && (!(1...12).contains(parts[0]) || !(1...( [31,29,31,30,31,30,31,31,30,31,30,31][max(0,min(11,parts[0]-1))] )).contains(parts[1])) || value.count != 5 { fail("Datum als MM-TT auswählen.", b) }
                        }
                    }
                } else { fail("Wähle eine bekannte Sonderfunktion.", b) }
            }
            if b.flag("configurationError") { fail("Korrigiere die erweiterte Konfiguration.", b) }
            let allowedOptions: Set<String>
            switch b.kind {
            case .function: allowedOptions = Set((b.function?.parameters.map(\.key) ?? []) + ["function", "inputCount"])
            case .and, .or, .xor: allowedOptions = ["inputCount"]
            case .digitalInput: allowedOptions = ["initial"]
            case .analogInput: allowedOptions = ["initial", "attribute", "minimum", "maximum"]
            case .analogOutput: allowedOptions = ["deadband"]
            case .markerContact, .analogContact: allowedOptions = ["markerID"]
            case .analogCompare: allowedOptions = ["threshold", "comparison"]
            case .state: allowedOptions = ["behavior"]
            case .stateMatch: allowedOptions = ["expected"]
            case .numeric: allowedOptions = ["threshold", "comparison"]
            case .constant: allowedOptions = ["value"]
            case .timeWindow: allowedOptions = ["mode", "after", "before", "weekdays"]
            case .button: allowedOptions = ["behavior", "duration", "retrigger"]
            case .latch: allowedOptions = ["priority"]
            case .onDelay, .offDelay, .pulse: allowedOptions = ["duration", "retrigger", "resettable", "durationSource"]
            case .output: allowedOptions = ["behavior"]
            case .haTrigger: allowedOptions = ["configuration", "signalBehavior", "signalDuration", "configurationError"]
            case .haCondition: allowedOptions = ["configuration", "configurationError"]
            case .haAction: allowedOptions = ["configuration", "actionBehavior", "offConfiguration", "configurationError", "parameterBindings"]
            default: allowedOptions = []
            }
            if !Set(b.options.keys).isSubset(of: allowedOptions) { fail("Nicht unterstützte Bausteinoptionen: " + Set(b.options.keys).subtracting(allowedOptions).sorted().joined(separator: ", "), b) }
            for key in ["duration", "threshold", "signalDuration"] where b.options[key] != nil {
                if b.options[key]?.number?.isFinite != true { fail("\(key) benötigt einen endlichen Zahlenwert.", b) }
            }
            for key in ["value", "configurationError"] where b.options[key] != nil {
                if b.options[key]?.bool == nil { fail("\(key) benötigt Ein oder Aus.", b) }
            }
            for key in ["expected", "comparison", "mode", "after", "before", "behavior", "retrigger", "signalBehavior", "actionBehavior"] where b.options[key] != nil {
                if b.options[key]?.string == nil { fail("Ungültiger Wert für \(key).", b) }
            }
            if let enabled = b.configuration.object?["enabled"], enabled.bool == nil { fail("Aktiviert benötigt Ein oder Aus.", b) }
            if b.kind == .state && b.text("behavior", "switch") != "switch" { fail("Wähle für ein Tastersignal den Taster-Baustein.", b) }
            if b.kind == .output && !["follow", "on", "off", "toggle"].contains(b.text("behavior", "follow")) { fail("Wähle ein gültiges Ausgangsverhalten.", b) }
            if b.kind == .button && !["momentary", "switch"].contains(b.text("behavior", "momentary")) { fail("Wähle Taster oder Schalter.", b) }
            if b.kind.isTimed && !["restart", "ignore"].contains(b.text("retrigger", "restart")) { fail("Ungültiges Verhalten bei erneutem Auslösen.", b) }
            if !b.x.isFinite || !b.y.isFinite { fail("Ungültige Bausteinposition.", b) }
            if b.negatedInputs.contains(where: { !(0..<b.inputCount).contains($0) }) { fail("Ungültiger negierter Eingang.", b) }
            for pin in 0..<b.inputCount {
                let n = g.wires.filter { $0.target == b.id && $0.input == pin }.count
                if n == 0 && b.kind != .haCondition && !(g.usesPLCCycle && b.unusedDigitalInput(pin) != nil) { fail(b.variableDuration && pin == 2 ? "Verbinde T mit einem Zeitwert in Sekunden, zum Beispiel einer Wertauswahl oder einem Analogmerker." : "Verbinde Eingang \(pin + 1).", b) }
                if n > 1 { fail("Verwende ODER, um mehrere Signale an einem Eingang zusammenzuführen.", b) }
            }
            if [.state, .stateMatch, .numeric, .button, .output].contains(b.kind) {
                if b.managedButton { inputs.insert(virtualInput(b)) }
                else if validEntity(b.entityID) { if b.kind != .output { inputs.insert(b.entityID) } }
                else { fail("Wähle eine gültige Entität.", b) }
            }
            if b.supportsVariableDuration && (b.options["durationSource"] != nil && b.options["durationSource"]?.string == nil || !["fixed", "input"].contains(b.text("durationSource", "fixed"))) { fail("Wähle eine feste Zeit oder den Eingang T.", b) }
            if b.kind.isTimed && !b.variableDuration && (!b.duration.isFinite || !(0.1...86400).contains(b.duration)) { fail("Die Dauer muss zwischen 0,1 Sekunden und 24 Stunden liegen.", b) }
            if [.numeric, .analogCompare].contains(b.kind) && (!b.number("threshold", 20).isFinite || ![">", ">=", "<", "<=", "==", "!="].contains(b.text("comparison", ">"))) { fail("Wähle einen gültigen Zahlenvergleich.", b) }
            if b.variableDuration, let wire = g.wires.first(where: { $0.target == b.id && $0.input == 2 }),
               let source = blocks[wire.source], source.function == .valueSelect {
                let candidates = [source.selectionDefault] + (0..<source.inputCount).map { source.selectionValue($0) }
                if candidates.contains(where: { !$0.isFinite || !(0.1...86400).contains($0) }) { fail("Die Wertauswahl an T enthält eine ungültige Laufzeit. Erlaubt sind 0,1 Sekunden bis 24 Stunden.", b) }
            }
            if b.kind == .timeWindow && !TimeWindow(block: b).valid { fail("Wähle ein gültiges Zeitfenster und Wochentage.", b) }
            if b.kind == .output {
                actions += 1
                if !["light", "switch", "fan", "input_boolean"].contains(b.entityID.components(separatedBy: ".").first ?? "") { fail("Der Schaltausgang unterstützt Licht, Schalter, Lüfter und Ein/Aus-Helfer.", b) }
            }
            if b.outputType != .digital && b.negated || b.negatedInputs.contains(where: { b.inputType($0) != .digital }) { fail("Nur Ein/Aus-Anschlüsse können logisch negiert werden.", b) }
            if b.kind.isContact {
                guard let id = b.markerID, let marker = blocks[id], marker.kind.isMarker, marker.kind.outputType == b.kind.outputType else { fail("Wähle einen passenden Merker dieses Programms.", b); continue }
            }
            if b.kind.isPLCInput {
                if !b.virtualPLC && !validEntity(b.entityID) { fail("Wähle eine gültige Eingangs-Entität.", b) }
                if b.kind == .digitalInput, let initial = b.options["initial"], initial.bool == nil { fail("Der Startwert benötigt Ein oder Aus.", b) }
                if b.kind == .analogInput {
                    for key in ["initial", "minimum", "maximum"] where b.options[key] != nil {
                        if b.options[key]?.number?.isFinite != true { fail("\(key) benötigt einen endlichen Zahlenwert.", b) }
                    }
                    if b.number("minimum", 0) > b.number("maximum", 100) || b.number("initial", 0) < b.number("minimum", 0) || b.number("initial", 0) > b.number("maximum", 100) { fail("Der Startwert muss im eingestellten Wertebereich liegen.", b) }
                    if let attribute = b.options["attribute"], attribute.string == nil || b.text("attribute").contains("#") { fail("Wähle einen gültigen Attributnamen.", b) }
                }
                inputs.insert(b.inputKey)
            }
            if b.kind.isPLCOutput && !b.virtualPLC {
                actions += 1
                let domains = b.kind == .digitalOutput ? ["light", "switch", "fan", "input_boolean"] : ["number", "input_number", "light"]
                if !validEntity(b.entityID) || !domains.contains(b.entityID.components(separatedBy: ".").first ?? "") { fail("Wähle eine schreibbare Ausgangs-Entität: " + domains.joined(separator: ", "), b) }
            }
            if b.kind == .analogOutput, let deadband = b.options["deadband"], deadband.number?.isFinite != true || b.number("deadband", 0.1) < 0 { fail("Die Mindeständerung muss eine endliche Zahl ab null sein.", b) }
            if b.kind == .haCondition {
                if let e = condition(b.configuration) { inputs.formUnion(e.dependencies) }
                else { fail("Diese Bedingung oder eine ihrer Optionen wird von Runtime 0.1 noch nicht ausgewertet. Unterstützt sind Zustand, Zahlenbereich, Zeitfenster und Hell/Dunkel ohne Versatz.", b) }
            }
            if b.kind == .haTrigger {
                let c = b.configuration.object ?? [:], type = HAConfiguration.type(b.configuration, role: .haTrigger)
                let common: Set<String> = ["trigger", "platform", "alias", "id", "enabled"]
                let allowed: Set<String>
                switch type {
                case "state":
                    allowed = common.union(["entity_id", "from", "to"])
                    let ids = SignalBridge.strings(c["entity_id"])
                    if ids.isEmpty || !ids.allSatisfy(validEntity) { fail("Wähle mindestens eine Entität.", b) }
                    inputs.formUnion(ids)
                    if ["from", "to"].contains(where: { c[$0] != nil && c[$0] != .null && c[$0]?.string == nil }) { fail("Von/Nach benötigt einen einzelnen Zustand.", b) }
                case "time":
                    allowed = common.union(["at"])
                    if secondsOfDay(c["at"]?.string ?? "") == nil { fail("Wähle eine feste Uhrzeit (HH:mm:ss).", b) }
                case "time_pattern":
                    allowed = common.union(["hours", "minutes", "seconds"])
                    if !["hours", "minutes", "seconds"].contains(where: { c[$0] != nil }) { fail("Stelle ein Zeitintervall ein.", b) }
                    for (key, max) in [("hours", 23), ("minutes", 59), ("seconds", 59)] where c[key] != nil {
                        if !validPattern(c[key]!, max: max) { fail("Ungültiges Zeitmuster für \(key).", b) }
                    }
                default: allowed = []; fail("Dieser Ereignisauslöser ist für Runtime 0.1 noch nicht verfügbar.", b)
                }
                if !Set(c.keys).isSubset(of: allowed) { fail("Noch nicht unterstützte Auslöseroptionen: \(Set(c.keys).subtracting(allowed).sorted().joined(separator: ", ")).", b) }
                if b.text("signalBehavior", "event") != "event" {
                    guard let c = SignalBridge.stateCondition(b), condition(c) != nil else { fail("Verwende für ein dauerhaftes Signal einen Zustands- oder Zeitfensterbaustein.", b); continue }
                }
                if !(0.1...10).contains(b.number("signalDuration", 0.5)) { fail("Die Ereignisimpulsdauer muss zwischen 0,1 und 10 Sekunden liegen.", b) }
            }
            if b.kind == .haAction {
                for error in b.parameterErrors { fail(error, b) }
                let c = b.configuration.object ?? [:]
                if let delay = c["delay"] {
                    if duration(delay) == nil || !Set(c.keys).isSubset(of: ["delay", "alias", "enabled"]) { fail("Warten benötigt eine feste Dauer von 0,1 Sekunden bis 24 Stunden.", b) }
                } else {
                    if !validAction(b.configuration) { fail("Wähle eine Aktion mit festen oder verknüpften Parametern. Templates, Ablaufvariablen und verschachtelte Aktionen sind noch nicht unterstützt.", b) }
                    if service(b.configuration) != "nodivra.log" { actions += 1 }
                }
                let behavior = SignalBridge.resolvedActionBehavior(b, in: g)
                if !["rising", "falling", "follow"].contains(behavior) { fail("Ungültiges Aktionsverhalten.", b) }
                if behavior == "follow", SignalBridge.offAction(b).map(validAction) != true { fail("Ein/Aus folgen benötigt eine gültige Aus-Aktion.", b) }
            }
        }
        var ownership: [String: UUID] = [:]
        for b in g.blocks {
            let key: String?
            if b.kind.isPLCOutput && !b.virtualPLC { key = "entity:" + b.entityID }
            else if b.kind == .output && b.text("behavior", "follow") == "follow" { key = "entity:" + b.entityID }
            else if b.kind == .haAction && SignalBridge.resolvedActionBehavior(b, in: g) == "follow" { key = "target:" + SignalBridge.targetKey(b.configuration) }
            else { key = nil }
            if let key { if ownership[key] != nil { fail("Mehrere Folgeausgänge steuern dasselbe Ziel. Fasse die Signale zunächst mit ODER zusammen; Zielprioritäten folgen in einer späteren Version.", b) }; ownership[key] = b.id }
        }
        return .init(issues: issues, inputs: inputs.sorted(), deviceActions: actions)
    }
    static func ordered(_ g: AutomationGraph) -> [Block] {
        var left = g.blocks, done = Set<UUID>(), result: [Block] = []
        while let i = left.firstIndex(where: { b in b.kind.isMarker || b.kind.isContact || g.wires.filter { $0.target == b.id }.allSatisfy { done.contains($0.source) } }) {
            let b = left.remove(at: i); done.insert(b.id); result.append(b)
        }
        return result
    }
    public static func virtualInput(_ b: Block) -> String { (b.kind.isPLCInput ? "nodivra_input." : "nodivra_button.") + b.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
    static func validEntity(_ s: String) -> Bool { s.range(of: "^[a-z_]+\\.[a-z0-9_]+$", options: .regularExpression) != nil }
    static func condition(_ c: ConfigValue) -> BooleanExpression? {
        var d = c.object ?? [:]; d.removeValue(forKey: "alias"); d.removeValue(forKey: "enabled")
        return SignalBridge.expression(.object(d))
    }
    static func service(_ c: ConfigValue) -> String { (c.object?["action"] ?? c.object?["service"])?.string ?? "" }
    static func validAction(_ c: ConfigValue) -> Bool {
        guard let o = c.object, Set(o.keys).isSubset(of: ["action", "service", "target", "data", "alias", "enabled"]), o["action"] == nil || o["service"] == nil,
              validEntity(service(c)), !c.json.contains("{{"), !c.json.contains("{%"), o["data"] == nil || o["data"]?.object != nil else { return false }
        if service(c) == "nodivra.log" { return o["target"] == nil && o["data"]?.object?["message"]?.string != nil }
        if let target = o["target"] {
            guard let t = target.object, Set(t.keys).isSubset(of: ["entity_id", "device_id", "area_id", "floor_id", "label_id"]) else { return false }
            for (_, value) in t { if SignalBridge.strings(value).isEmpty || (value.string == nil && value.array?.allSatisfy({ $0.string != nil }) != true) { return false } }
        }
        return true
    }
    static func duration(_ c: ConfigValue) -> Double? {
        if let o = c.object {
            guard Set(o.keys).isSubset(of: ["days", "hours", "minutes", "seconds", "milliseconds"]), o.values.allSatisfy({ $0.number != nil && $0.number! >= 0 }) else { return nil }
        }
        guard let n = HAFormSchema.seconds(c), n.isFinite, (0.1...86400).contains(n) else { return nil }; return n
    }
    static func secondsOfDay(_ s: String) -> Int? {
        let a = s.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(a.count), s.split(separator: ":").count == a.count, (0...23).contains(a[0]), (0...59).contains(a[1]), a.count == 2 || (0...59).contains(a[2]) else { return nil }
        return a[0] * 3600 + a[1] * 60 + (a.count == 3 ? a[2] : 0)
    }
    static func patternText(_ c: ConfigValue) -> String { c.string ?? c.number.map { String(Int($0)) } ?? "" }
    static func validPattern(_ c: ConfigValue, max: Int) -> Bool {
        if let n = c.number, !n.isFinite || n.rounded() != n || n < 0 || n > Double(max) { return false }
        let s = patternText(c); if s == "*" { return true }
        if s.hasPrefix("/") { return Int(s.dropFirst()).map { (1...(max + 1)).contains($0) } ?? false }
        return Int(s).map { (0...max).contains($0) } ?? false
    }
    static func matches(_ c: ConfigValue?, _ n: Int, default fallback: String = "*") -> Bool {
        let s = c.map(patternText) ?? fallback
        if s == "*" { return true }; if s.hasPrefix("/"), let divisor = Int(s.dropFirst()), divisor > 0 { return n % divisor == 0 }; return Int(s) == n
    }
}
public extension AutomationGraph {
    static var runtimeExample: AutomationGraph {
        let clock = Block(kind: .haTrigger, title: "Alle 5 Sekunden", x: 80, y: 170, options: ["configuration": .object(["trigger": .string("time_pattern"), "seconds": .string("/5")])], catalogID: "trigger.pattern")
        let wait = Block(kind: .haAction, title: "2 Sekunden warten", x: 410, y: 170, options: ["configuration": .object(["delay": .object(["seconds": .number(2)])])], catalogID: "action.delay")
        let log = Block(kind: .haAction, title: "Im Protokoll anzeigen", x: 740, y: 170, options: ["configuration": .object(["action": .string("nodivra.log"), "data": .object(["message": .string("Nodivra läuft – Zeitimpuls und Wartezeit erfolgreich.")])])], catalogID: "runtime.log")
        return .init(title: "Mein erster Runtime-Test", blocks: [clock, wait, log], wires: [.init(source: clock.id, target: wait.id, input: 0), .init(source: wait.id, target: log.id, input: 0)])
    }
}
