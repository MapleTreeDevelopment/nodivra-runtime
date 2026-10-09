import Foundation

public extension Block {
    var supportsVariableDuration: Bool { [.onDelay, .offDelay, .pulse].contains(kind) }
    var variableDuration: Bool { supportsVariableDuration && text("durationSource", "fixed") == "input" }
    // Keep R at pin 1 and T at pin 2, including when opening older timers.
    var hasTimerReset: Bool { supportsVariableDuration && (flag("resettable") || variableDuration) }
    var configurableInputCount: Bool { isGate || function == .valueSelect }
    var valueSelectionCount: Int {
        let count = number("inputCount", 4)
        return count.isFinite ? Int(min(8, max(2, count))) : 4
    }
    var selectionUsesTime: Bool { function == .valueSelect && text("valueUnit", "duration") == "duration" }
    func selectionValue(_ pin: Int) -> Double { number("value\(pin + 1)", 120) }
    var selectionDefault: Double { number("defaultValue", 300) }
    func selectionDescription(_ value: Double) -> String {
        guard selectionUsesTime else { return value.formatted() }
        if value >= 3600 && value.truncatingRemainder(dividingBy: 3600) == 0 { return "\((value / 3600).formatted()) Std." }
        if value >= 60 && value.truncatingRemainder(dividingBy: 60) == 0 { return "\((value / 60).formatted()) Min." }
        return "\(value.formatted()) Sek."
    }
}

public extension AutomationGraph {
    var usesVariableParameters: Bool { blocks.contains { ($0.supportsVariableDuration && $0.options["durationSource"] != nil) || $0.function == .valueSelect } }
}
