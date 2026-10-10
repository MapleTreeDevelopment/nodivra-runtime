import Foundation

public struct RuntimeInputDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public var pin: Int
    public var label: String
    public var status: String
    public var value: ConfigValue?
    public var source: String?
    public var negated: Bool
    public var id: Int { pin }
    public var description: String {
        let text = value.map { v in v.bool.map { $0 ? "Ein" : "Aus" } ?? HAConfiguration.compact(v) } ?? "Unbekannt"
        switch status {
        case "unused": return "Nicht verbunden · neutral (\(text))"
        case "missing": return "Nicht verbunden · Wert fehlt"
        case "unknown": return "Verbunden · Wert unbekannt"
        default: return text + (negated ? " · negiert" : "")
        }
    }
}

public struct RuntimeTimerDiagnostic: Codable, Equatable, Sendable {
    public var configured: Double?
    public var captured: Double?
    public var elapsed: Double?
    public var remaining: Double?
    public var phase: String
    public var reason: String
    public var changedAt: Double
    // Logical engine time, never wall time. Stored to preserve diagnostics on restore.
    var started: Double?
}

public struct RuntimeBlockDiagnostic: Codable, Equatable, Sendable {
    public var summary: String
    public var inputs: [RuntimeInputDiagnostic]
    public var timer: RuntimeTimerDiagnostic?
}

extension RuntimeEngine {
    func diagnosticInputs(_ b: Block) -> [RuntimeInputDiagnostic] {
        (0..<b.inputCount).map { pin in
            let w = diagnosticWires[b.id]?[pin]
            let inverted = b.negatedInputs.contains(pin)
            var value: ConfigValue?
            if let w {
                switch b.inputType(pin) {
                case .digital: value = signals[w.source].map { .bool(inverted ? !$0 : $0) }
                case .analog: value = analogSignals[w.source].map(ConfigValue.number)
                default: value = parameterSignals[w.source]
                }
            } else if b.inputType(pin) == .digital && package.graph.usesPLCCycle {
                value = b.unusedDigitalInput(pin).map { .bool(inverted ? !$0 : $0) }
            }
            return .init(pin: pin, label: b.inputLabels[pin], status: w == nil ? (value == nil ? "missing" : "unused") : (value == nil ? "unknown" : "known"), value: value, source: w?.source.uuidString, negated: inverted)
        }
    }
    public func blockDiagnostics() -> [String: RuntimeBlockDiagnostic] {
        Dictionary(uniqueKeysWithValues: package.graph.blocks.map { b in
            let inputs = diagnosticInputs(b)
            let unknown = inputs.filter { $0.status == "unknown" || $0.status == "missing" }
            let q = signals[b.id].map { $0 ? "Ein" : "Aus" } ?? "unbekannt"
            var summary = "Ausgang: \(q)"
            if let analog = analogSignals[b.id] { summary = "Wert: \(analog)" }
            if b.isGate || b.kind == .not {
                if !unknown.isEmpty {
                    summary = unknown.map { "\($0.label): \($0.status == "missing" ? "Verbindung fehlt" : "Wert unbekannt")" }.joined(separator: ", ") + " – Ausgang bleibt unbekannt."
                } else if b.kind == .and || b.function == .nand {
                    let low = inputs.filter { $0.value?.bool == false }.map(\.label)
                    summary = (low.isEmpty ? "Alle Eingänge sind Ein" : low.joined(separator: ", ") + " ist Aus") + " – Ausgang: \(q)."
                } else if b.kind == .or || b.function == .nor {
                    let high = inputs.filter { $0.value?.bool == true }.map(\.label)
                    summary = (high.isEmpty ? "Alle Eingänge sind Aus" : high.joined(separator: ", ") + " ist Ein") + " – Ausgang: \(q)."
                } else if b.kind == .xor {
                    summary = "\(inputs.filter { $0.value?.bool == true }.count) Eingänge sind Ein – Ausgang: \(q)."
                } else if b.kind == .not { summary = "Eingang wird umgekehrt – Ausgang: \(q)." }
                else { summary = "Flankenauswertung – Ausgang: \(q)." }
                if b.negated { summary += " Ausgang negiert." }
            } else if b.kind.isPLCInput || [.state, .stateMatch, .numeric].contains(b.kind) {
                let key = b.kind.isPLCInput ? b.inputKey : b.entityID
                if states[key] == nil && !b.virtualPLC { summary = "Kein Zustand für diese Entität vorhanden." }
                else if signals[b.id] == nil && analogSignals[b.id] == nil { summary = "Entitätswert unbekannt, nicht verfügbar oder nicht auswertbar." }
            }
            var timer = timerDiagnostics[b.id]
            if timer?.phase == "running", let end = diagnosticDeadline(b) {
                timer?.remaining = max(0, end - time)
                if let total = timer?.captured { timer?.elapsed = max(0, total - max(0, end - time)) }
            }
            if let timer { summary = timer.reason }
            return (b.id.uuidString, .init(summary: summary, inputs: inputs, timer: timer))
        })
    }

    func diagnosticDeadline(_ b: Block) -> Double? { deadlines[b.id] ?? functions[b.id]?.deadline }

    // Multi-phase timers can advance across a phase boundary between samples.
    // Derive the full phase from the engine's anchor, not from remaining time.
    private func timerPhase(_ b: Block) -> (duration: Double?, exactDuration: Double?, label: String?) {
        guard let f = b.function else { return (nil, nil, nil) }
        func n(_ key: String) -> Double { b.options[key]?.number ?? f.parameters.first { $0.key == key }?.initial.number ?? 0 }
        if f == .clockPulse, let start = functions[b.id]?.started {
            let phase = (time - start).truncatingRemainder(dividingBy: n("onTime") + n("offTime"))
            let high = phase < n("onTime"), total = n(high ? "onTime" : "offTime")
            return (total, total, high ? "Einschaltphase" : "Ausschaltphase")
        }
        if f == .delayedPulse, let start = functions[b.id]?.started {
            if time < start { return (n("delay"), n("delay"), "Startverzögerung") }
            let phase = (time - start).truncatingRemainder(dividingBy: n("duration") + n("pause"))
            let high = phase < n("duration"), total = n(high ? "duration" : "pause")
            return (total, total, high ? "Impulsphase" : "Pause")
        }
        if [.onOffDelay, .randomDelay].contains(f) {
            return (n(functions[b.id]?.target == true ? "onTime" : "offTime"), nil, f == .randomDelay ? "Zufallsverzögerung" : nil)
        }
        return (f.parameters.contains { $0.key == "duration" } ? n("duration") : nil, nil, nil)
    }

    mutating func updateTimerDiagnostics(previousEnds: [UUID: Double], restoring: Bool) {
        for b in diagnosticTimerBlocks {
            let inputs = diagnosticInputs(b)
            let reset = b.hasTimerReset || (b.function != nil && b.function != .debounce) ? inputs.first { $0.pin == 1 }?.value?.bool : false
            let end = diagnosticDeadline(b)
            let before = previousEnds[b.id]
            var item = timerDiagnostics[b.id] ?? .init(configured: nil, captured: nil, elapsed: nil, remaining: nil, phase: "idle", reason: "Wartet auf ein Startsignal.", changedAt: time, started: nil)
            let phase = timerPhase(b)
            item.configured = b.variableDuration ? inputs.first { $0.pin == 2 }?.value?.number : [.onDelay, .offDelay, .pulse].contains(b.kind) ? b.duration : b.kind == .haAction ? b.configuration.object?["delay"].flatMap(RuntimeCompiler.duration) : phase.duration
            if reset == nil {
                if item.reason != "Reset-Eingang R ist unbekannt; kein verlässlicher Zeitstatus." { item.changedAt = time }
                item.phase = "unknown"; item.reason = "Reset-Eingang R ist unbekannt; kein verlässlicher Zeitstatus."; item.remaining = nil; item.elapsed = nil
            } else if b.function != nil && inputs.contains(where: { $0.status == "unknown" || $0.status == "missing" }) {
                if item.reason != "Eingang unbekannt; kein verlässlicher Zeitstatus." { item.changedAt = time }
                item.phase = "unknown"; item.reason = "Eingang unbekannt; kein verlässlicher Zeitstatus."; item.remaining = nil; item.elapsed = nil
            } else if let end, end > time {
                if !restoring && (before == nil || abs(end - before!) > 0.001) {
                    item.captured = phase.exactDuration ?? (end - time)
                    item.started = end - (item.captured ?? 0); item.changedAt = time
                }
                item.phase = "running"; item.remaining = max(0, end - time)
                item.elapsed = item.captured.map { max(0, $0 - (end - time)) }
                item.reason = restoring ? "Gespeicherte Restzeit wird fortgesetzt." : phase.label.map { "Zeit läuft · \($0)." } ?? "Zeit läuft."
            } else if reset == true {
                if item.phase != "reset" { item.changedAt = time }
                item.phase = "reset"; item.reason = "Zurückgesetzt: R ist Ein."; item.remaining = nil; item.elapsed = nil
            } else if let before {
                item.changedAt = time; item.remaining = nil
                if before <= time {
                    item.phase = "completed"; item.elapsed = item.captured; item.reason = "Zeit abgelaufen."
                } else {
                    item.phase = "cancelled"; item.elapsed = item.started.map { max(0, time - $0) }
                    item.reason = inputs.first?.value == nil ? "Abgebrochen: Eingang unbekannt." : b.kind == .offDelay ? "Nachlauf aufgehoben: Eingang wieder Ein." : "Abgebrochen: Eingangssignal geändert."
                }
            }
            timerDiagnostics[b.id] = item
        }
    }
}

extension Block {
    var isDiagnosticTimer: Bool {
        [.onDelay, .offDelay, .pulse].contains(kind) || (kind == .haAction && configuration.object?["delay"] != nil) || function.map { [.onOffDelay, .debounce, .randomDelay, .retentiveOnDelay, .wipingRelay, .delayedPulse, .clockPulse, .staircase, .comfort].contains($0) } == true
    }
}
