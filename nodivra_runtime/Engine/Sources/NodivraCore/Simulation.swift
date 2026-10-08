import Foundation

public struct SimulationEvent: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let time: Double
    public let entityID: String
    public let value: Bool
    public let blockID: UUID
}
public struct SimulatedAction: Sendable, Identifiable {
    public let id: UUID
    public let time: Double
    public let blockID: UUID
    public let configuration: ConfigValue
}
/// Static HA delay forms only. Templates need HA's template context and must not
/// be treated as an instantaneous action by the local simulator.
enum ActionSimulation {
    static func delay(_ configuration: ConfigValue) -> Double? {
        guard let c = configuration.object, let value = c["delay"],
              Set(c.keys).isSubset(of: ["delay", "alias", "enabled", "continue_on_error"]),
              c["enabled"] == nil || c["enabled"]?.bool != nil else { return nil }
        func number(_ value: ConfigValue) -> Double? {
            let n = value.number ?? value.string.flatMap(Double.init)
            return n.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        let result: Double?
        if let n = number(value) { result = n }
        else if let s = value.string {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard (2...3).contains(parts.count), let hours = Double(parts[0]), let minutes = Double(parts[1]),
                  hours.isFinite, hours >= 0, hours.rounded() == hours,
                  (0..<60).contains(minutes), minutes.rounded() == minutes else { return nil }
            let seconds = parts.count == 3 ? Double(parts[2]) : 0
            guard let seconds, (0..<60).contains(seconds) else { return nil }
            result = hours * 3600 + minutes * 60 + seconds
        } else if let fields = value.object {
            let units: [String: Double] = ["days":86400, "hours":3600, "minutes":60, "seconds":1, "milliseconds":0.001]
            guard !fields.isEmpty, Set(fields.keys).isSubset(of: Set(units.keys)) else { return nil }
            var total = 0.0
            for (key, value) in fields { guard let n = number(value) else { return nil }; total += n * units[key]! }
            result = total
        } else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    static func supports(_ configuration: ConfigValue) -> Bool {
        if configuration.object?["enabled"]?.bool == false { return true }
        return (configuration.object?["action"] ?? configuration.object?["service"])?.string != nil || delay(configuration) != nil
    }
}
/// Isolated virtual state and clock; no credentials, network clients or device writes.
public struct LocalSimulator: Sendable {
    public let plan: AutomationPlan
    public private(set) var states: [String: String]
    public private(set) var output: Bool?
    public private(set) var events: [SimulationEvent] = []
    public private(set) var time: Double = 0
    public private(set) var deadlines: [UUID: Double] = [:]
    private var previous: [UUID: [Bool?]] = [:]
    private var previousOutputs: [UUID: Bool] = [:]
    public private(set) var actionEvents: [SimulatedAction] = []
    private var previousActions: [UUID: Bool] = [:]
    private var activeActions: [String: UUID] = [:]
    private var completionDeadlines: [String: Double] = [:]
    private struct RunningAction: Sendable {
        let rule: ActionRule
        let deadline: Double
        let waiting: Bool
    }
    private var runningActions: [UUID: RunningAction] = [:]
    private var queuedActions: [UUID: Int] = [:]
    public private(set) var warnings: [String] = []
    private var clockOrigin: Date
    public let calendar: Calendar
    public var date: Date { clockOrigin.addingTimeInterval(time) }
    public var usesClock: Bool { plan.blockExpressions.values.contains(where: \.usesClock) }
    public func evaluate(_ expression: BooleanExpression) -> Bool { expression.evaluate(states, at: date, calendar: calendar) }
    public mutating func setDate(_ date: Date) {
        guard date.timeIntervalSince1970.isFinite else { return }
        clockOrigin = date.addingTimeInterval(-time)
        propagate([], clockChanged: true)
    }
    public init(plan: AutomationPlan, snapshot: [String: String], date: Date = Date(), calendar: Calendar = .current) {
        self.plan = plan; self.states = snapshot; self.clockOrigin = date; self.calendar = calendar
        for helper in plan.helpers {
            if states[helper.entityID] == nil { states[helper.entityID] = helper.requirement.kind == .timer ? "idle" : helper.requirement.kind == .number ? "0" : "off" }
        }
        for rule in plan.runtimeRules { previous[rule.blockID] = rule.inputs.map { $0.available(states) ? evaluate($0) : nil } }
        for rule in plan.actionRules where rule.expression.available(states) { previousActions[rule.blockID] = evaluate(rule.expression) }
        for rule in plan.outputs where rule.expression.available(states) { previousOutputs[rule.blockID] = evaluate(rule.expression) }
    }
    @discardableResult public mutating func set(_ entityID: String, state: String) -> SimulationEvent? {
        guard plan.simulationSupported, plan.inputs.contains(entityID), states[entityID] != state else { return nil }
        let previousID = events.last?.id
        propagate([(entityID, state)])
        return events.last?.id != previousID ? events.last : nil
    }
    public mutating func advance(by seconds: Double) {
        guard plan.simulationSupported, seconds.isFinite, seconds >= 0, seconds <= 86400 else { return }
        let target = time + seconds
        var steps = 0
        while time < target || deadlines.values.contains(where: { $0 <= target + 1e-9 }) || completionDeadlines.values.contains(where: { $0 <= target + 1e-9 }) || runningActions.values.contains(where: { $0.deadline <= target + 1e-9 }) {
            steps += 1; guard steps <= 10000 else { break }
            let nextDeadline = min(deadlines.values.min() ?? .infinity, completionDeadlines.values.min() ?? .infinity, runningActions.values.map(\.deadline).min() ?? .infinity)
            // Construct an exact wall-clock boundary first. Adding a fractional
            // remainder to elapsed time can round just below the minute and
            // evaluate the previous minute's condition instead.
            let minuteDate = Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 60) + 1) * 60)
            let nextMinute = usesClock ? minuteDate.timeIntervalSince(clockOrigin) : .infinity
            let next = min(nextDeadline, nextMinute)
            guard next <= target + 1e-9 else { break }
            time = next
            // A time-window boundary can cancel a delay expiring at the same instant.
            if nextMinute <= nextDeadline { propagate([], clockChanged: true) }
            for entity in completionDeadlines.keys.sorted() where completionDeadlines[entity]! <= time + 1e-9 {
                completionDeadlines.removeValue(forKey: entity); propagate([(entity, "off")])
            }
            let dueActions = runningActions.filter { $0.value.deadline <= time + 1e-9 }.keys.sorted { $0.uuidString < $1.uuidString }
            for id in dueActions {
                guard let run = runningActions.removeValue(forKey: id) else { continue }
                var changes: [(String, String)] = []
                if run.waiting { completeAction(run.rule, changes: &changes) }
                else {
                    if let entity = run.rule.completionEntity { changes.append((entity, "off")) }
                    // Deliver the falling edge before a zero-duration queued run
                    // can produce its next completion pulse.
                    propagate(changes); changes = []
                    startNextAction(run.rule, changes: &changes)
                }
                propagate(changes)
            }
            let due = deadlines.filter { $0.value <= time + 1e-9 }.keys.sorted { $0.uuidString < $1.uuidString }
            for id in due {
                guard deadlines[id] != nil, let rule = plan.runtimeRules.first(where: { $0.blockID == id }) else { continue }
                deadlines.removeValue(forKey: id)
                if let timer = rule.timerEntity { states[timer] = "idle" }
                let input = rule.inputs[0]
                switch rule.kind {
                case .button, .pulse: propagate([(rule.signalEntity, "off")])
                case .onDelay:
                    if input.available(states) && evaluate(input) { propagate([(rule.signalEntity, "on")]) }
                case .offDelay:
                    if input.available(states) && !evaluate(input) { propagate([(rule.signalEntity, "off")]) }
                default: break
                }
            }
        }
        time = target
    }
    public func remaining(_ blockID: UUID) -> Double? {
        if let run = runningActions[blockID], run.waiting { return max(0, run.deadline - time) }
        return deadlines[blockID].map { max(0, $0 - time) }
    }
    private mutating func startAction(_ rule: ActionRule, changes: inout [(String, String)]) {
        let config = rule.configuration
        if config.object?["enabled"]?.bool != false {
            actionEvents.append(.init(id: UUID(), time: time, blockID: rule.blockID, configuration: config))
            if let duration = ActionSimulation.delay(config), duration > 0 {
                runningActions[rule.blockID] = .init(rule: rule, deadline: time + duration, waiting: true)
                return
            }
            applyService(config)
        }
        completeAction(rule, changes: &changes)
    }
    private mutating func completeAction(_ rule: ActionRule, changes: inout [(String, String)]) {
        if let entity = rule.completionEntity {
            runningActions[rule.blockID] = .init(rule: rule, deadline: time + 0.1, waiting: false)
            changes.append((entity, "on"))
        } else { startNextAction(rule, changes: &changes) }
    }
    private mutating func startNextAction(_ rule: ActionRule, changes: inout [(String, String)]) {
        if let count = queuedActions[rule.blockID], count > 0 {
            queuedActions[rule.blockID] = count - 1
            startAction(rule, changes: &changes)
        }
    }
    private mutating func applyService(_ config: ConfigValue) {
        let service = (config.object?["action"] ?? config.object?["service"])?.string ?? ""
        for target in SignalBridge.strings(config.object?["target"]?.object?["entity_id"]) {
            if service.hasSuffix(".turn_on") { states[target] = "on" }
            if service.hasSuffix(".turn_off") { states[target] = "off" }
            if service.hasSuffix(".toggle") { states[target] = states[target] == "on" ? "off" : "on" }
        }
    }
    private mutating func propagate(_ changes: [(String, String)], clockChanged: Bool = false) {
        var queue = (clockChanged ? [("", "")] : []) + changes, cursor = 0
        while cursor < queue.count && cursor < 4000 {
            let (entity, state) = queue[cursor]; cursor += 1
            let clockTick = entity.isEmpty
            if !clockTick {
                guard states[entity] != state else { continue }
                states[entity] = state
            }
            for rule in plan.runtimeRules where rule.inputs.contains(where: { (clockTick ? $0.usesClock : $0.dependencies.contains(entity)) }) {
                let before = previous[rule.blockID] ?? Array(repeating: nil, count: rule.inputs.count)
                let now: [Bool?] = rule.inputs.map { $0.available(states) ? evaluate($0) : nil }
                previous[rule.blockID] = now
                guard now.allSatisfy({ $0 != nil }) else { continue }
                let on = now[0] == true, rising = on && before[0] != true, falling = !on && before[0] != false
                func signal(_ value: Bool) { queue.append((rule.signalEntity, value ? "on" : "off")) }
                switch rule.kind {
                case .button:
                    if rising && (rule.retrigger || deadlines[rule.blockID] == nil) { deadlines[rule.blockID] = time + rule.duration }
                case .onDelay:
                    if rising { deadlines[rule.blockID] = time + rule.duration; if let timer = rule.timerEntity { states[timer] = "active" } }
                    if falling { deadlines.removeValue(forKey: rule.blockID); if let timer = rule.timerEntity { states[timer] = "idle" }; signal(false) }
                case .offDelay:
                    if rising { deadlines.removeValue(forKey: rule.blockID); if let timer = rule.timerEntity { states[timer] = "idle" }; signal(true) }
                    if falling { deadlines[rule.blockID] = time + rule.duration; if let timer = rule.timerEntity { states[timer] = "active" } }
                case .pulse:
                    if rising && (rule.retrigger || states[rule.signalEntity] != "on") {
                        deadlines[rule.blockID] = time + rule.duration; if let timer = rule.timerEntity { states[timer] = "active" }; signal(true)
                    }
                case .latch:
                    if now[1] == true { signal(false) } else if on { signal(true) }
                default: break
                }
            }
            let groups = Dictionary(grouping: plan.actionRules, by: \.groupKey)
            for key in groups.keys.sorted() {
                let group = groups[key]!
                guard group.contains(where: { clockTick ? $0.expression.usesClock : $0.expression.dependencies.contains(entity) }) else { continue }
                guard group.allSatisfy({ $0.expression.available(states) }) else {
                    for r in group { previousActions.removeValue(forKey: r.blockID) }; continue
                }
                var rising: [ActionRule] = [], falling: [ActionRule] = []
                for r in group {
                    let value = evaluate(r.expression), before = previousActions.updateValue(evaluate(r.expression), forKey: r.blockID)
                    if value && before != true { rising.append(r) }
                    if !value && before != false { falling.append(r) }
                }
                guard !rising.isEmpty || !falling.isEmpty else { continue }
                let first = group[0]
                let chosen: ActionRule?
                var off = false
                if first.behavior == "follow" {
                    if let newest = rising.last { chosen = newest }
                    else if let active = group.first(where: { $0.blockID == activeActions[key] }), evaluate(active.expression) { continue }
                    else if let active = group.first(where: { evaluate($0.expression) }) { chosen = active }
                    else { chosen = group.first { $0.blockID == activeActions[key] } ?? first; off = true }
                } else { chosen = first.behavior == "falling" ? falling.first : rising.first }
                guard let chosen else { continue }
                if chosen.behavior != "follow" {
                    if runningActions[chosen.blockID] != nil {
                        let count = queuedActions[chosen.blockID, default: 0]
                        if count < 9 { queuedActions[chosen.blockID] = count + 1 }
                        else if warnings.isEmpty { warnings.append("Die Warteschlange einer Aktion ist voll (10 Ausführungen). Weitere Starts werden wie in Home Assistant verworfen.") }
                    } else { startAction(chosen, changes: &queue) }
                    continue
                }
                let config = off ? chosen.offConfiguration! : chosen.configuration
                if off { activeActions.removeValue(forKey: key) } else { activeActions[key] = chosen.blockID }
                if let selected = chosen.selectionEntity { states[selected] = off ? "0" : String(chosen.selectionIndex) }
                actionEvents.append(.init(id: UUID(), time: time, blockID: chosen.blockID, configuration: config))
                applyService(config)
                if !off, let completion = chosen.completionEntity {
                    queue.append((completion, "on")); completionDeadlines[completion] = time + 0.1
                }
            }
            for rule in plan.outputs where clockTick ? rule.expression.usesClock : rule.expression.dependencies.contains(entity) {
                guard rule.expression.available(states) else { previousOutputs.removeValue(forKey: rule.blockID); continue }
                let value = evaluate(rule.expression)
                let before = previousOutputs.updateValue(value, forKey: rule.blockID)
                if rule.expression.usesClock && before == value { continue }
                let result: Bool
                switch rule.behavior {
                case "on": guard value else { continue }; result = true
                case "off": guard value else { continue }; result = false
                case "toggle": guard value else { continue }; result = states[rule.entityID] != "on"
                default: result = value
                }
                states[rule.entityID] = result ? "on" : "off"
                events.append(.init(id: UUID(), time: time, entityID: rule.entityID, value: result, blockID: rule.blockID))
                if rule.entityID == plan.outputEntity { output = result }
            }
        }
        if actionEvents.count > 200 { actionEvents.removeFirst(actionEvents.count - 200) }
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
}
