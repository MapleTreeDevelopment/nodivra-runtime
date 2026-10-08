import Foundation

/// A local wall-clock condition, with minute precision like HA's now() templates.
/// Weekdays refer to the current calendar day, including after midnight.
public struct TimeWindow: Sendable, Equatable {
    public let mode: String
    public let after: String
    public let before: String
    public let weekdays: [String]
    private let wellTyped: Bool
    public static let dayKeys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    public init(block: Block) {
        wellTyped = ["mode", "after", "before"].allSatisfy { block.options[$0] == nil || block.options[$0]?.string != nil }
            && (block.options["weekdays"] == nil || block.options["weekdays"]?.array?.allSatisfy { $0.string != nil } == true)
        mode = block.text("mode", "between")
        after = block.text("after", "22:00:00")
        before = block.text("before", "06:00:00")
        weekdays = block.options["weekdays"]?.array?.compactMap(\.string) ?? Self.dayKeys
    }
    private static func minutes(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), parts[2] == "00",
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }
    public var valid: Bool {
        wellTyped && ["between", "after", "before", "allDay"].contains(mode) &&
        Self.minutes(after) != nil && Self.minutes(before) != nil &&
        !weekdays.isEmpty && Set(weekdays).count == weekdays.count && weekdays.allSatisfy(Self.dayKeys.contains) &&
        (mode != "between" || after != before)
    }
    public var boundaryTimes: Set<String> {
        var result: Set<String> = ["00:00:00"]
        if mode == "between" || mode == "after" { result.insert(after) }
        if mode == "between" || mode == "before" { result.insert(before) }
        return result
    }
    public func evaluate(at date: Date, calendar: Calendar = .current) -> Bool {
        guard valid else { return false }
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let weekday = Self.dayKeys[((parts.weekday ?? 1) + 5) % 7]
        guard weekdays.contains(weekday) else { return false }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let start = Self.minutes(after)!, end = Self.minutes(before)!
        switch mode {
        case "after": return minute >= start
        case "before": return minute < end
        case "allDay": return true
        default: return start < end ? minute >= start && minute < end : minute >= start || minute < end
        }
    }
    public var template: String {
        let clock = "(now().hour * 60 + now().minute)"
        let start = Self.minutes(after) ?? 0, end = Self.minutes(before) ?? 0
        let time: String
        switch mode {
        case "after": time = "\(clock) >= \(start)"
        case "before": time = "\(clock) < \(end)"
        case "allDay": time = "true"
        default: time = "(\(clock) >= \(start) \(start < end ? "and" : "or") \(clock) < \(end))"
        }
        let days = Self.dayKeys.indices.filter { weekdays.contains(Self.dayKeys[$0]) }.map(String.init).joined(separator: ", ")
        return "(now().weekday() in [\(days)] and (\(time)))"
    }
    public var summary: String {
        let clock: String
        switch mode {
        case "after": clock = "Ab \(after.prefix(5)) bis Mitternacht"
        case "before": clock = "Bis \(before.prefix(5))"
        case "allDay": clock = "Ganztägig"
        default: clock = "\(after.prefix(5))–\(before.prefix(5))"
        }
        let days = weekdays.count == 7 ? "täglich" : weekdays.map { ["mon":"Mo", "tue":"Di", "wed":"Mi", "thu":"Do", "fri":"Fr", "sat":"Sa", "sun":"So"][$0] ?? $0 }.joined(separator: ", ")
        return "\(clock) · \(days)"
    }
}

extension Block {
    public var durationDescription: String {
        let seconds = duration
        if seconds >= 3600 && seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\((seconds / 3600).formatted()) Std." }
        if seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\((seconds / 60).formatted()) Min." }
        return "\(seconds.formatted()) Sek."
    }
}
