import Foundation

public struct RuntimeCommand: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var blockID: UUID
    public var configuration: ConfigValue
    public var time: Double
}
public struct RuntimeSnapshot: Codable, Sendable {
    public var time: Double
    public var signals: [String: Bool]
    public var analogSignals: [String: Double]
    public var parameterSignals: [String: ConfigValue]?
    public var cycle: UInt64
    public var remaining: [String: Double]
    public var pending: [String]
    public var commands: [RuntimeCommand]
    public var fault: String?
}

/// Pure state machine. No sockets, HA services, helpers or filesystem access.
/// The caller must explicitly acknowledge an action before its successor runs.
public struct RuntimeEngine: Sendable {
    public let package: RuntimePackage
    public let validation: RuntimeValidation
    public private(set) var time: Double = 0
    public private(set) var date: Date
    public private(set) var states: [String: String]
    public private(set) var signals: [UUID: Bool] = [:]
    public private(set) var analogSignals: [UUID: Double] = [:]
    public private(set) var parameterSignals: [UUID: ConfigValue] = [:]
    private var followConfigurations: [UUID: ConfigValue] = [:]
    private var followSignals: [UUID: Bool] = [:]
    public private(set) var cycle: UInt64 = 0
    private var functions: [UUID: PLCFunctionState] = [:]
    private var functionRemaining: [UUID: Double] = [:]
    private var markerValues: [UUID: ConfigValue] = [:]
    private var previousAnalog: [UUID: Double] = [:]
    public private(set) var fault: String?
    private var ordered: [Block]
    private var calendar: Calendar
    private var lastStates: [String: String]
    private var previous: [UUID: Bool] = [:]
    private var deadlines: [UUID: Double] = [:]
    private var completions: [UUID: Double] = [:]
    private var pending: [UUID: RuntimeCommand] = [:]
    private var memory: [UUID: Bool] = [:]
    private var clockStamp: [UUID: Int] = [:]
    private var actionTimes: [Double] = []
    private var lastNow: Double = 0
    public init(package: RuntimePackage, states: [String: String] = [:], date: Date = Date()) throws {
        let v = RuntimeCompiler.validate(package)
        guard v.valid else { throw CompilationError(diagnostics: v.issues.map { .init($0.message, blockID: $0.blockID) }) }
        self.package = package; validation = v; self.states = states; lastStates = states; self.date = date
        ordered = RuntimeCompiler.ordered(package.graph)
        calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: package.timeZone)!
        for b in package.graph.blocks where b.kind.isMarker { markerValues[b.id] = b.kind == .marker ? .bool(false) : .number(0) }
        _ = evaluate(seed: true)
    }
    public func remaining(_ id: UUID) -> Double? { functionRemaining[id] ?? deadlines[id].map { max(0, $0 - time) } }
    public mutating func step(now: Double, date: Date, states: [String: String]) -> RuntimeSnapshot {
        guard fault == nil else { return snapshot([]) }
        guard now.isFinite, now >= lastNow, now - lastNow <= 60 else {
            fault = "Ausführung pausiert: Zeitbasis unterbrochen. Erneut aktivieren, um mit aktuellen Zuständen zu starten."; return snapshot([])
        }
        time = now; lastNow = now; self.date = date; self.states = states
        cycle += 1
        let commands = evaluate(seed: false); lastStates = states
        return snapshot(commands)
    }
    public mutating func acknowledge(_ commandID: UUID, success: Bool) {
        guard let pair = pending.first(where: { $0.value.id == commandID }) else { return }
        pending.removeValue(forKey: pair.key)
        if success { completions[pair.key] = time + 0.2 }
        else { fault = "Aktion nicht bestätigt. Die Automation wurde pausiert; es erfolgt keine automatische Wiederholung." }
    }
    public func snapshot(_ commands: [RuntimeCommand] = []) -> RuntimeSnapshot {
        .init(time: time, signals: Dictionary(uniqueKeysWithValues: signals.map { ($0.key.uuidString, $0.value) }), analogSignals: Dictionary(uniqueKeysWithValues: analogSignals.map { ($0.key.uuidString, $0.value) }), parameterSignals: Dictionary(uniqueKeysWithValues: parameterSignals.map { ($0.key.uuidString, $0.value) }), cycle: cycle, remaining: Dictionary(uniqueKeysWithValues: deadlines.map { ($0.key.uuidString, max(0, $0.value - time)) }).merging(Dictionary(uniqueKeysWithValues: functionRemaining.map { ($0.key.uuidString, $0.value) }), uniquingKeysWith: { _, b in b }), pending: pending.keys.map(\.uuidString), commands: commands, fault: fault)
    }
    private mutating func evaluate(seed: Bool) -> [RuntimeCommand] {
        var commands: [RuntimeCommand] = []
        let g = package.graph
        // Publish the process image before evaluating any combinational block. Contacts
        // and direct marker outputs always expose exactly the same previous-cycle value.
        for b in ordered where b.kind.isMarker || b.kind.isContact {
            let stored = markerValues[b.kind.isMarker ? b.id : (b.markerID ?? b.id)]
            if b.kind.outputType == .analog { analogSignals[b.id] = stored?.number }
            else { signals[b.id] = stored?.bool.map { b.negated ? !$0 : $0 } }
        }
        for b in ordered {
            if b.kind.isMarker || b.kind.isContact { continue }

            func input(_ pin: Int) -> Bool? {
                guard let w = g.wires.first(where: { $0.target == b.id && $0.input == pin }) else {
                    // LOGO-style unconnected S/R pins are zero in new PLC programs.
                    return g.usesPLCCycle ? b.unusedDigitalInput(pin).map { b.negatedInputs.contains(pin) ? !$0 : $0 } : nil
                }
                guard let value = signals[w.source] else { return nil }
                return b.negatedInputs.contains(pin) ? !value : value
            }
            func analogInput(_ pin: Int = 0) -> Double? { g.wires.first { $0.target == b.id && $0.input == pin }.flatMap { analogSignals[$0.source] } }
            func parameterInput(_ pin: Int, _ type: SignalType) -> ConfigValue? {
                switch type {
                case .digital: return input(pin).map(ConfigValue.bool)
                case .analog: return analogInput(pin).map(ConfigValue.number)
                default: return g.wires.first { $0.target == b.id && $0.input == pin }.flatMap { parameterSignals[$0.source] }
                }
            }
            func evaluate(_ expression: BooleanExpression) -> Bool? { expression.available(states) ? expression.evaluate(states, at: date, calendar: calendar) : nil }
            let prior = previous[b.id], incoming = input(0)
            var value: Bool?
            let c = b.configuration.object ?? [:]
            switch b.kind {
            case .function:
                if b.typedSelection {
                    var chosen: ConfigValue? = b.selectedValue("defaultValue")
                    for pin in 0..<b.inputCount {
                        guard let active = input(pin) else { chosen = nil; break }
                        if active { chosen = b.selectedValue("value\(pin + 1)"); break }
                    }
                    parameterSignals[b.id] = chosen
                    value = chosen?.bool; analogSignals[b.id] = chosen?.number
                    break
                }
                var state = functions[b.id] ?? PLCFunctionState()
                let result = state.evaluate(b, digital: (0..<b.inputCount).map { b.inputType($0) == .digital ? input($0) : nil }, analog: (0..<b.inputCount).map { b.inputType($0) == .analog ? analogInput($0) : nil }, now: time, date: date, calendar: calendar, seed: seed)
                functions[b.id] = state; value = result.0; analogSignals[b.id] = result.1; functionRemaining[b.id] = result.2
            case .digitalInput:
                let raw = states[b.inputKey] ?? (b.virtualPLC ? b.initialInput : "unavailable")
                value = ["on", "true", "1"].contains(raw) ? true : ["off", "false", "0"].contains(raw) ? false : nil
            case .analogInput:
                let raw = states[b.inputKey] ?? (b.virtualPLC ? b.initialInput : "unavailable")
                analogSignals[b.id] = Double(raw).flatMap { $0.isFinite ? $0 : nil }
            case .analogCompare:
                if let n = analogInput() {
                    let t = b.number("threshold", 20)
                    switch b.text("comparison", ">") {
                    case ">": value = n > t; case ">=": value = n >= t; case "<": value = n < t
                    case "<=": value = n <= t; case "==": value = n == t; default: value = n != t
                    }
                }
            case .digitalOutput, .analogOutput:
                value = incoming.map { b.negated ? !$0 : $0 }
                let n = analogInput()
                if b.kind == .analogOutput { analogSignals[b.id] = n; value = nil }
                let changed = b.kind == .digitalOutput ? (value != nil && prior != nil && value != prior) : (n != nil && previousAnalog[b.id] != nil && n != previousAnalog[b.id] && abs(n! - previousAnalog[b.id]!) >= b.number("deadband", 0.1))
                if !seed && changed && !b.virtualPLC {
                    let domain = b.entityID.components(separatedBy: ".")[0]
                    var data: [String: ConfigValue] = [:]
                    let action: String
                    if b.kind == .digitalOutput { action = domain + (value == true ? ".turn_on" : ".turn_off") }
                    else if domain == "light" {
                        guard let n, (0...100).contains(n) else { fault = "\(b.title): Helligkeit muss zwischen 0 und 100 % liegen."; return [] }
                        action = n == 0 ? "light.turn_off" : "light.turn_on"
                        if n > 0 { data["brightness_pct"] = .number(n) }
                    } else { action = domain + ".set_value"; data["value"] = .number(n!) }
                    actionTimes.removeAll { time - $0 >= 60 }
                    if pending[b.id] != nil { fault = "\(b.title): Vorherige Ausgangsaktion noch nicht bestätigt."; return [] }
                    if actionTimes.count >= 30 { fault = "Schutzgrenze erreicht: höchstens 30 Aktionen pro Minute je Automation."; return [] }
                    let command = RuntimeCommand(blockID: b.id, configuration: .object(["action": .string(action), "target": .object(["entity_id": .string(b.entityID)]), "data": .object(data)]), time: time)
                    commands.append(command); pending[b.id] = command; actionTimes.append(time)
                }
                previous[b.id] = value
                // Accumulate small analog changes against the last sent value.
                if seed || changed || n == nil || previousAnalog[b.id] == nil { previousAnalog[b.id] = n }
            case .marker, .analogMarker, .markerContact, .analogContact: break
            case .state: value = evaluate(.entity(b.entityID))
            case .stateMatch: value = evaluate(.matches(b.entityID, b.text("expected", "on")))
            case .numeric: value = evaluate(.numeric(b.entityID, b.text("comparison", ">"), b.number("threshold", 20)))
            case .constant: value = b.flag("value", true)
            case .timeWindow: value = TimeWindow(block: b).evaluate(at: date, calendar: calendar)
            case .button:
                let id = b.managedButton ? RuntimeCompiler.virtualInput(b) : b.entityID
                let current = evaluate(.entity(id))
                if b.momentary {
                    if !seed && current == true && prior == false && (b.text("retrigger", "restart") == "restart" || deadlines[b.id] == nil) { deadlines[b.id] = time + b.duration }
                    value = deadlines[b.id].map { $0 > time } ?? false
                    if value == false { deadlines.removeValue(forKey: b.id) }
                } else { value = current }
                previous[b.id] = current
            case .and, .or, .xor:
                let values = (0..<b.inputCount).map(input)
                if values.allSatisfy({ $0 != nil }) { value = b.kind == .and ? values.allSatisfy { $0 == true } : b.kind == .or ? values.contains(true) : values.filter { $0 == true }.count % 2 == 1 }
            case .not: value = incoming.map { !$0 }
            case .onDelay, .offDelay, .pulse:
                if b.hasTimerReset && input(1) != false {
                    deadlines.removeValue(forKey: b.id); memory.removeValue(forKey: b.id)
                    value = input(1) == true ? false : nil; previous[b.id] = false
                    break
                }
                let startsTimer: Bool = !seed && incoming != nil && (
                    b.kind == .offDelay ? incoming == false && prior == true :
                    incoming == true && prior == false && (b.kind != .pulse || b.text("retrigger", "restart") == "restart" || deadlines[b.id] == nil))
                var duration = b.duration
                if b.variableDuration && startsTimer {
                    guard let requested = analogInput(2), requested.isFinite, (0.1...86400).contains(requested) else {
                        deadlines.removeValue(forKey: b.id); memory.removeValue(forKey: b.id)
                        signals.removeValue(forKey: b.id)
                        fault = "\(b.title): T benötigt einen gültigen Zeitwert von 0,1 Sekunden bis 24 Stunden. Ausführung pausiert."
                        return []
                    }
                    duration = requested
                }
                if let current = incoming {
                    if seed {
                        value = b.kind == .offDelay ? current : false
                    } else {
                        switch b.kind {
                        case .onDelay:
                            if !current { deadlines.removeValue(forKey: b.id); memory[b.id] = false }
                            else if prior == false { deadlines[b.id] = time + duration }
                            if let end = deadlines[b.id], end <= time { memory[b.id] = true; deadlines.removeValue(forKey: b.id) }
                            value = memory[b.id] ?? false
                        case .offDelay:
                            if current { deadlines.removeValue(forKey: b.id) }
                            else if prior == true { deadlines[b.id] = time + duration }
                            value = current || (deadlines[b.id].map { $0 > time } ?? false)
                            if !current && value == false { deadlines.removeValue(forKey: b.id) }
                        default:
                            if current && prior == false && (b.text("retrigger", "restart") == "restart" || deadlines[b.id] == nil) { deadlines[b.id] = time + duration }
                            value = deadlines[b.id].map { $0 > time } ?? false
                            if value == false { deadlines.removeValue(forKey: b.id) }
                        }
                    }
                } else { deadlines.removeValue(forKey: b.id); memory.removeValue(forKey: b.id) }
                previous[b.id] = incoming
            case .latch:
                if let set = input(0), let reset = input(1) {
                    if !seed { if set && b.text("priority", "reset") == "set" { memory[b.id] = true } else if reset { memory[b.id] = false } else if set { memory[b.id] = true } }
                    value = memory[b.id] ?? false
                }
            case .haCondition:
                if c["enabled"]?.bool == false { value = true }
                else if let expression = RuntimeCompiler.condition(b.configuration) { value = evaluate(expression) }
                if g.wires.contains(where: { $0.target == b.id }) { value = value.flatMap { a in incoming.map { a && $0 } } }
            case .haTrigger:
                if b.text("signalBehavior", "event") == "state", let config = SignalBridge.stateCondition(b), let e = RuntimeCompiler.condition(config) { value = evaluate(e) }
                else {
                    let type = HAConfiguration.type(b.configuration, role: .haTrigger)
                    var fired = false
                    if type == "state" {
                        fired = SignalBridge.strings(c["entity_id"]).contains { id in
                            guard let before = lastStates[id], let after = states[id], before != after, !["unknown", "unavailable"].contains(before), !["unknown", "unavailable"].contains(after) else { return false }
                            return (c["from"]?.string == nil || c["from"]?.string == before) && (c["to"]?.string == nil || c["to"]?.string == after)
                        }
                    } else {
                        let stamp = Int(date.timeIntervalSince1970), parts = calendar.dateComponents([.hour, .minute, .second], from: date)
                        if clockStamp[b.id] != stamp {
                            if type == "time" { fired = RuntimeCompiler.secondsOfDay(c["at"]?.string ?? "") == (parts.hour! * 3600 + parts.minute! * 60 + parts.second!) }
                            else {
                                fired = RuntimeCompiler.matches(c["hours"], parts.hour!) && RuntimeCompiler.matches(c["minutes"], parts.minute!, default: c["hours"] == nil ? "*" : "0") && RuntimeCompiler.matches(c["seconds"], parts.second!, default: c["hours"] == nil && c["minutes"] == nil ? "*" : "0")
                            }
                            clockStamp[b.id] = stamp
                        }
                    }
                    if !seed && fired && c["enabled"]?.bool != false { deadlines[b.id] = time + b.number("signalDuration", 0.5) }
                    value = deadlines[b.id].map { $0 > time } ?? false
                    if value == false { deadlines.removeValue(forKey: b.id) }
                }
                if c["enabled"]?.bool == false { value = false }
            case .output, .haAction:
                let signal = incoming.map { b.negated ? !$0 : $0 }
                let behavior = b.kind == .output ? (b.text("behavior", "follow") == "follow" ? "follow" : "rising") : SignalBridge.resolvedActionBehavior(b, in: g)
                let rising = signal == true && prior == false, falling = signal == false && prior == true
                if b.hasActionParameters && behavior == "follow" {
                    // Coalesce parameter changes while a service call is pending. The digital
                    // desired state is kept separately, so an OFF edge is never lost.
                    if seed { followSignals[b.id] = signal }
                    let changedState = signal != nil && followSignals[b.id] != nil && signal != followSignals[b.id]
                    let ownsOn = followConfigurations[b.id] != nil && followSignals[b.id] == true
                    if !seed && pending[b.id] == nil && c["enabled"]?.bool != false && (changedState || signal == true && ownsOn) {
                        var resolved: ConfigValue?
                        if signal == false {
                            var last = b
                            if let sent = followConfigurations[b.id] { last.options["configuration"] = sent }
                            resolved = SignalBridge.offAction(last)
                        } else {
                            resolved = b.resolvingParameters(parameterInput, frozenTarget: ownsOn ? followConfigurations[b.id]?.object?["target"] : nil)
                        }
                        guard let resolved, RuntimeCompiler.validAction(resolved), RuntimeCompiler.validResolvedParameters(resolved) else {
                            fault = "\(b.title): Ein verknüpfter Parameter fehlt oder enthält einen ungültigen Wert. Ausführung pausiert."; return []
                        }
                        if changedState || resolved != followConfigurations[b.id] {
                            actionTimes.removeAll { time - $0 >= 60 }
                            guard actionTimes.count < 30 else { fault = "Schutzgrenze erreicht: höchstens 30 Aktionen pro Minute je Automation."; return [] }
                            let command = RuntimeCommand(blockID: b.id, configuration: resolved, time: time)
                            commands.append(command); pending[b.id] = command; actionTimes.append(time)
                            followSignals[b.id] = signal
                            followConfigurations[b.id] = signal == true ? resolved : nil
                        }
                    }
                    if followSignals[b.id] == nil { followSignals[b.id] = signal }
                    value = completions[b.id].map { $0 > time } ?? false
                    break
                }
                let changed = (behavior != "falling" && rising) || (behavior != "rising" && falling)
                previous[b.id] = signal
                if !seed && changed && c["enabled"]?.bool != false {
                    if pending[b.id] != nil || deadlines[b.id] != nil {
                        fault = "\(b.title): Neuer Start während einer laufenden Aktion. Die Automation wurde angehalten."
                    } else {
                        let resolved = b.hasActionParameters ? b.resolvingParameters(parameterInput) : b.configuration
                        if b.kind == .haAction {
                            guard let resolved else { fault = "\(b.title): Ein verknüpfter Parameter fehlt oder ist ungültig."; return [] }
                            if let delay = resolved.object?["delay"] {
                                guard let duration = RuntimeCompiler.duration(delay) else { fault = "\(b.title): Die Wartezeit muss zwischen 0,1 Sekunden und 24 Stunden liegen."; return [] }
                                deadlines[b.id] = time + duration
                                value = false; break
                            }
                            guard RuntimeCompiler.validAction(resolved), RuntimeCompiler.validResolvedParameters(resolved) else { fault = "\(b.title): Die aufgelösten Aktionsparameter sind ungültig."; return [] }
                        }
                        var config: ConfigValue
                        if b.kind == .output {
                            let domain = b.entityID.components(separatedBy: ".")[0]
                            let setting = b.text("behavior", "follow")
                            let action = setting == "toggle" ? ".toggle" : setting == "off" || (setting == "follow" && signal == false) ? ".turn_off" : ".turn_on"
                            config = .object(["action": .string(domain + action), "target": .object(["entity_id": .string(b.entityID)])])
                        } else { config = signal == false && behavior == "follow" ? SignalBridge.offAction(b)! : resolved! }
                        actionTimes.removeAll { time - $0 >= 60 }
                        if actionTimes.count >= 30 { fault = "Schutzgrenze erreicht: höchstens 30 Aktionen pro Minute je Automation." }
                        else {
                            let command = RuntimeCommand(blockID: b.id, configuration: config, time: time)
                            commands.append(command); pending[b.id] = command; actionTimes.append(time)
                        }
                    }
                }
                if let end = deadlines[b.id], end <= time { deadlines.removeValue(forKey: b.id); completions[b.id] = time + 0.2 }
                value = completions[b.id].map { $0 > time } ?? false
            }
            if b.negated && b.kind != .haAction && b.kind != .output && b.kind != .digitalOutput { value = value.map { !$0 } }
            signals[b.id] = value
            if fault != nil { return [] }
        }
        if !seed {
            // Commit simultaneously; never expose a partially updated marker bank.
            var next = markerValues
            for b in ordered where b.kind.isMarker {
                let source = g.wires.first { $0.target == b.id && $0.input == 0 }?.source
                if b.kind == .analogMarker { next[b.id] = source.flatMap { analogSignals[$0] }.map(ConfigValue.number) ?? .null }
                else { next[b.id] = source.flatMap { signals[$0] }.map { .bool(b.negatedInputs.contains(0) ? !$0 : $0) } ?? .null }
            }
            markerValues = next
        }
        return commands
    }
}
