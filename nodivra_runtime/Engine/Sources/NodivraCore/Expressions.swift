import Foundation

public indirect enum BooleanExpression: Sendable, Equatable {
    case timeWindow(TimeWindow)
    case entity(String), matches(String, String), numeric(String, String, Double), constant(Bool)
    case and(BooleanExpression, BooleanExpression), or(BooleanExpression, BooleanExpression), xor(BooleanExpression, BooleanExpression), not(BooleanExpression)
    public var dependencies: Set<String> {
        switch self {
        case .entity(let id), .matches(let id, _), .numeric(let id, _, _): [id]
        case .and(let a, let b), .or(let a, let b), .xor(let a, let b): a.dependencies.union(b.dependencies)
        case .not(let a): a.dependencies
        case .constant, .timeWindow: []
        }
    }
    public func evaluate(_ states: [String: String], at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .timeWindow(let window): return window.evaluate(at: date, calendar: calendar)
        case .entity(let id): return states[id] == "on"
        case .matches(let id, let value): return states[id] == value
        case .numeric(let id, let op, let value):
            guard let n = Double(states[id] ?? ""), n.isFinite else { return false }
            switch op { case ">=": return n >= value; case "<": return n < value; case "<=": return n <= value; case "==": return n == value; case "!=": return n != value; default: return n > value }
        case .constant(let b): return b
        case .and(let a, let b): return a.evaluate(states, at: date, calendar: calendar) && b.evaluate(states, at: date, calendar: calendar)
        case .or(let a, let b): return a.evaluate(states, at: date, calendar: calendar) || b.evaluate(states, at: date, calendar: calendar)
        case .xor(let a, let b): return a.evaluate(states, at: date, calendar: calendar) != b.evaluate(states, at: date, calendar: calendar)
        case .not(let a): return !a.evaluate(states, at: date, calendar: calendar)
        }
    }
    public func available(_ states: [String: String]) -> Bool {
        switch self {
        case .entity(let id): states[id] == "on" || states[id] == "off"
        case .matches(let id, _): states[id] != nil && !["unknown","unavailable"].contains(states[id]!)
        case .numeric(let id, _, _): Double(states[id] ?? "")?.isFinite == true
        case .constant, .timeWindow: true
        case .and(let a, let b), .or(let a, let b), .xor(let a, let b): a.available(states) && b.available(states)
        case .not(let a): a.available(states)
        }
    }
    public var timeWindows: [TimeWindow] {
        switch self {
        case .timeWindow(let window): [window]
        case .and(let a, let b), .or(let a, let b), .xor(let a, let b): a.timeWindows + b.timeWindows
        case .not(let a): a.timeWindows
        default: []
        }
    }
    public var usesClock: Bool { !timeWindows.isEmpty }
    private func q(_ text: String) -> String { YAMLWriter.quote(text) }
    public var template: String {
        switch self {
        case .entity(let id): "is_state('\(id)', 'on')"
        case .matches(let id, let s): "is_state('\(id)', \(q(s)))"
        case .numeric(let id, let op, let v): "(states('\(id)') | float(0) \(op) \(v))"
        case .timeWindow(let window): window.template
        case .constant(let b): b ? "true" : "false"
        case .and(let a, let b): "(\(a.template) and \(b.template))"
        case .or(let a, let b): "(\(a.template) or \(b.template))"
        case .xor(let a, let b): "(\(a.template) != \(b.template))"
        case .not(let a): "(not \(a.template))"
        }
    }
    public var availability: String {
        switch self {
        case .entity(let id): "states('\(id)') in ['on', 'off']"
        case .matches(let id, _): "states('\(id)') not in ['unknown', 'unavailable']"
        case .numeric(let id, _, _): "is_number(states('\(id)'))"
        case .constant, .timeWindow: "true"
        case .and(let a, let b), .or(let a, let b), .xor(let a, let b): "(\(a.availability) and \(b.availability))"
        case .not(let a): a.availability
        }
    }
}
