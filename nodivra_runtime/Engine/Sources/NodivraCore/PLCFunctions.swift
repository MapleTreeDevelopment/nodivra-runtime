import Foundation

public struct PLCParameter: Sendable {
    public let key: String
    public let label: String
    public let initial: ConfigValue
    public let choices: [String]
    public let range: ClosedRange<Double>?
    public init(_ key: String, _ label: String, _ value: Double, _ range: ClosedRange<Double> = -1e9...1e9) { self.key = key; self.label = label; initial = .number(value); choices = []; self.range = range }
    public init(_ key: String, _ label: String, _ value: String, _ choices: [String] = []) { self.key = key; self.label = label; initial = .string(value); self.choices = choices; range = nil }
}
public enum PLCFunction: String, Codable, CaseIterable, Sendable {
    case valueSelect
    case nand, nor, andEdge, nandEdge, edge, onOffDelay, retentiveOnDelay, wipingRelay, delayedPulse, clockPulse, randomDelay, staircase, comfort
    case yearClock, astroClock, stopwatch, counter, hours, frequency, firstCycle
    case threshold, differenceThreshold, comparator, monitor, amplifier, impulseRelay, shiftRegister, multiplexer, ramp, pi, pwm, math, mathError, filter, minMax, average, toInteger, toFloat, debounce, limit
    public var title: String {
        switch self {
        case .valueSelect: "Wertauswahl"
        case .nand: "NAND"; case .nor: "NOR"; case .andEdge: "UND mit Flankenauswertung"; case .nandEdge: "NAND mit Flankenauswertung"; case .edge: "Flankenimpuls"
        case .onOffDelay: "Ein-/Ausschaltverzögerung"; case .retentiveOnDelay: "Speichernde Einschaltverzögerung"; case .wipingRelay: "Wischrelais"; case .delayedPulse: "Flankengetriggertes Wischrelais"
        case .clockPulse: "Asynchroner Impulsgeber"; case .randomDelay: "Zufallsgenerator"; case .staircase: "Treppenlichtschalter"; case .comfort: "Komfortschalter"
        case .yearClock: "Jahresschaltuhr"; case .astroClock: "Astronomische Uhr"; case .stopwatch: "Stoppuhr"
        case .counter: "Vor-/Rückwärtszähler"; case .hours: "Betriebsstundenzähler"; case .frequency: "Schwellwertschalter · Frequenz"
        case .firstCycle: "Anlaufimpuls"
        case .threshold: "Analoger Schwellwertschalter"; case .differenceThreshold: "Differenzschwellwertschalter"; case .comparator: "Analogkomparator"; case .monitor: "Analogüberwachung"; case .amplifier: "Analogverstärker"
        case .impulseRelay: "Stromstoßrelais"; case .shiftRegister: "Schieberegister"; case .multiplexer: "Analoger Multiplexer"; case .ramp: "Rampensteuerung"; case .pi: "PI-Regler"; case .pwm: "Impulsdauermodulator · PWM"
        case .math: "Mathematische Funktion"; case .mathError: "Rechenfehler erkennen"; case .filter: "Analogfilter"; case .minMax: "Max/Min"; case .average: "Mittelwert"; case .toInteger: "Gleitpunkt → Ganzzahl"; case .toFloat: "Ganzzahl → Gleitpunkt"; case .debounce: "Signal entprellen"; case .limit: "Analogwert begrenzen"
        }
    }
    public var category: String {
        switch self {
        case .nand, .nor, .andEdge, .nandEdge, .edge: "Grundfunktionen"
        case .onOffDelay, .retentiveOnDelay, .wipingRelay, .delayedPulse, .clockPulse, .randomDelay, .staircase, .comfort, .stopwatch, .debounce: "Zeitfunktionen"
        case .yearClock, .astroClock: "Schaltuhren"
        case .counter, .hours, .frequency: "Zähler"
        case .impulseRelay, .shiftRegister, .firstCycle: "Speicher & Relais"
        case .ramp, .pi, .pwm: "Regelung"
        default: "Analogfunktionen"
        }
    }
    public var pins: [(String, SignalType)] {
        switch self {
        case .valueSelect: (1...4).map { ("I\($0)", .digital) }
        case .nand, .nor, .andEdge, .nandEdge: (1...5).map { ("I\($0)", .digital) }
        case .yearClock, .astroClock, .firstCycle: []
        case .counter: [("Cnt", .digital), ("Dir", .digital), ("R", .digital)]
        case .hours: [("En", .digital), ("R", .digital)]
        case .clockPulse: [("En", .digital), ("R", .digital), ("Inv", .digital)]
        case .frequency: [("Fre", .digital)]
        case .impulseRelay: [("Trg", .digital), ("S", .digital), ("R", .digital)]
        case .shiftRegister: [("In", .digital), ("Trg", .digital), ("Dir", .digital), ("R", .digital)]
        case .multiplexer: [("En", .digital), ("S1", .digital), ("S2", .digital)]
        case .pi: [("PV", .analog), ("R", .digital)]
        case .ramp: [("En", .digital), ("Sel", .digital), ("R", .digital)]
        case .pwm: [("Ax", .analog), ("En", .digital)]
        case .monitor: [("Ax", .analog), ("En", .digital)]
        case .comparator, .math: [("Ax", .analog), ("Ay", .analog)]
        case .minMax, .average: [("Ax", .analog), ("R", .digital)]
        case .threshold, .differenceThreshold, .amplifier, .mathError, .filter, .toInteger, .toFloat, .limit: [("Ax", .analog)]
        case .edge, .debounce: [("Trg", .digital)]
        default: [("Trg / En", .digital), ("R", .digital)]
        }
    }
    public var analogOutput: Bool { [.valueSelect, .stopwatch, .amplifier, .multiplexer, .ramp, .pi, .math, .filter, .minMax, .average, .toInteger, .toFloat, .limit].contains(self) }
    public var hasValueOutput: Bool { [.counter, .hours, .frequency].contains(self) }
    public var parameters: [PLCParameter] {
        let on = PLCParameter("onTime", "Einschaltzeit · s", 5, 0.1...86400), off = PLCParameter("offTime", "Ausschaltzeit · s", 5, 0.1...86400)
        let duration = PLCParameter("duration", "Dauer · s", 5, 0.1...86400)
        let limits = [PLCParameter("on", "Einschaltschwelle", 20), PLCParameter("off", "Ausschaltschwelle", 18)]
        return switch self {
        case .valueSelect: [.init("valueUnit", "Werte als", "duration", ["duration", "number"]), .init("defaultValue", "Standardwert", 300)] + (1...8).map { .init("value\($0)", "Wert I\($0)", 120) }
        case .nand, .nor, .andEdge, .nandEdge, .firstCycle: []
        case .edge: [.init("edge", "Flanke", "Steigend", ["Steigend", "Fallend", "Beide"])]
        case .onOffDelay, .clockPulse, .randomDelay: [on, off]
        case .retentiveOnDelay, .wipingRelay, .debounce: [duration]
        case .delayedPulse: [.init("delay", "Wartezeit · s", 1, 0...86400), duration, .init("count", "Impulse", 1, 1...1000), .init("pause", "Impulspause · s", 1, 0.1...86400)]
        case .staircase, .comfort: [duration, .init("warning", "Vorwarnung vor Ende · s (0 = aus)", 0, 0...86400), .init("warningLength", "Unterbrechung zur Warnung · s", 0.5, 0.1...60)] + (self == .comfort ? [.init("longPress", "Dauerlicht ab Tastdauer · s", 2, 0.1...60)] : [])
        case .yearClock: [.init("start", "Ab · MM-TT", "01-01"), .init("end", "Bis · einschließlich MM-TT", "12-31")]
        case .astroClock: [.init("latitude", "Breitengrad", 52, -90...90), .init("longitude", "Längengrad", 13, -180...180), .init("sunriseOffset", "Versatz Sonnenaufgang · min", 0, -720...720), .init("sunsetOffset", "Versatz Sonnenuntergang · min", 0, -720...720)]
        case .stopwatch: []
        case .counter: [.init("startValue", "Startwert", 0, -999999999...999999999)] + limits
        case .hours: [.init("interval", "Wartungsintervall · h", 100, 0.001...1e6)]
        case .frequency: [.init("window", "Messfenster · s", 1, 0.1...60)] + limits
        case .threshold, .comparator: limits
        case .differenceThreshold: [.init("on", "Einschaltschwelle", 20), .init("delta", "Differenz zur Ausschaltschwelle", -2)]
        case .monitor: [.init("delta", "Erlaubte Abweichung ±", 2, 0...1e9)]
        case .amplifier: [.init("gain", "Verstärkung", 1), .init("offset", "Offset", 0)]
        case .impulseRelay: [.init("priority", "Bei gleichzeitigem Setzen und Rücksetzen", "Rücksetzen", ["Rücksetzen", "Setzen"])]
        case .shiftRegister: [.init("length", "Registerlänge", 8, 1...32), .init("tap", "Ausgangsbit", 1, 1...32)]
        case .multiplexer: (1...4).map { .init("value\($0)", "Wert \($0)", Double($0 * 25)) }
        case .ramp: [.init("level1", "Stufe 1", 25), .init("level2", "Stufe 2", 75), .init("rate", "Änderung je Sekunde", 10, 0.001...1e9), .init("initial", "Startwert", 0)]
        case .pi: [.init("setpoint", "Sollwert", 20), .init("kp", "Verstärkung Kp", 1), .init("ti", "Nachstellzeit Ti · s", 60, 0.1...86400), .init("minimum", "Ausgang Minimum", 0), .init("maximum", "Ausgang Maximum", 100)]
        case .pwm: [.init("period", "Periode · s", 10, 0.2...86400), .init("minimum", "Eingang bei 0 %", 0), .init("maximum", "Eingang bei 100 %", 100)]
        case .math: [.init("operation", "Rechenart", "+", ["+", "−", "×", "÷"])]
        case .mathError: []
        case .filter: [.init("samples", "Filterbreite · Abtastwerte", 8, 1...256)]
        case .minMax: [.init("mode", "Wert", "Maximum", ["Maximum", "Minimum"])]
        case .average: [.init("samples", "Abtastwerte je Mittelwert", 10, 1...1000), .init("interval", "Abtastabstand · s", 1, 0.1...86400)]
        case .toInteger: [.init("resolution", "Auflösung · Eingang / Auflösung", 1, 0.001...1000), .init("rounding", "Rundung", "Abschneiden", ["Abschneiden", "Runden", "Aufrunden", "Abrunden"]), .init("width", "Zahlenbereich", "32 Bit", ["16 Bit", "32 Bit"])]
        case .toFloat: [.init("resolution", "Auflösung · Ganzzahl × Auflösung", 1, 0.001...1000)]
        case .limit: [.init("minimum", "Minimum", 0), .init("maximum", "Maximum", 100)]
        }
    }
    public var summary: String {
        switch self {
        case .counter: "Zählt steigende Flanken. Dir = Ein zählt abwärts. R setzt auf den Startwert. Q folgt den Schwellen, AQ liefert den Zählwert."
        case .hours: "Summiert die Einschaltzeit. Q meldet das Wartungsintervall; AQ zeigt Stunden. R setzt zurück."
        case .firstCycle: "Ein für genau den ersten Zyklus nach dem bewussten Start eines Programms. Kann angeschlossene Aktionen beim Start auslösen. Nach Runtime-Neustart bleiben Programme zunächst pausiert."
        case .valueSelect: "Jeder Ein-Eingang wählt seinen eingestellten Wert. Bei mehreren aktiven Eingängen hat die kleinere Nummer Vorrang. Sind alle Aus, gilt der Standardwert. Zeiten werden als Sekunden an T weitergegeben; kein zusätzlicher HA-Helfer nötig."
        case .frequency: "Zählt erkannte Flanken je Messfenster und liefert Hz. Für langsame HA-Signale, nicht für Hardware-Hochgeschwindigkeitszähler."
        case .stopwatch: "Misst Sekunden, solange En Ein ist. R hat Vorrang und setzt auf null."
        case .retentiveOnDelay: "Ein Impuls startet die Zeit. Q bleibt nach Ablauf Ein bis R. Speicherung während des Programmlaufs."
        case .wipingRelay: "Schaltet beim Einschalten für die Dauer Ein. Ein fallender Eingang beendet den Impuls vorzeitig."
        case .delayedPulse: "Eine steigende Flanke startet nach der Wartezeit die eingestellte Impulsfolge. Neue Flanken starten die Folge neu. R bricht ab."
        case .randomDelay: "Verzögert jeden Wechsel um eine zufällige Zeit zwischen null und der eingestellten Ein-/Ausschaltzeit."
        case .staircase: "Drücken schaltet Ein. Beim Loslassen beginnt die Nachlaufzeit; erneutes Drücken verlängert sie. Optionales kurzes Ausschalten warnt vor Ablauf. R beendet den Ablauf."
        case .comfort: "Kurzes Drücken schaltet Ein; beim Loslassen beginnt die Nachlaufzeit. Langes Drücken aktiviert Dauerlicht. Ein erneuter Tastendruck oder R schaltet aus."
        case .impulseRelay: "Jede steigende Trg-Flanke schaltet um. S setzt, R setzt zurück. Der Vorrang bei S und R ist wählbar."
        case .astroClock: "Ein zwischen berechnetem Sonnenaufgang und Sonnenuntergang. Für Dunkelheit den Ausgang negieren. Standort und Versatz sind einstellbar."
        case .yearClock: "Jährliches Datumsfenster einschließlich beider Tage, auch über den Jahreswechsel. Zeitzone des Programms."
        case .shiftRegister: "Schiebt bei jeder steigenden Trg-Flanke. Dir kehrt die Richtung um; R leert das Register. Q zeigt das ausgewählte Bit."
        case .pi: "PI-Regler mit Ausgangsbegrenzung und Begrenzung des Integrators. R setzt den Integrator zurück. Sollwert und Ausgangsgrenzen sind einstellbar."
        case .mathError: "Ein bei fehlendem oder ungültigem Analogwert, etwa nach Division durch null. Vor dem Freigeben realer Aktionen verwenden."
        case .monitor: "Speichert Ax bei steigender En-Flanke und meldet, solange aktiviert, eine Überschreitung der erlaubten Abweichung."
        case .filter: "Gleitender Mittelwert der letzten N bekannten Abtastwerte, ein Wert je Engine-Zyklus. Unbekannte Werte leeren das Messfenster."
        case .average: "Nimmt Werte im eingestellten Zeitabstand auf. Nach N Messungen erscheint ein neuer Mittelwert; bis dahin bleibt der letzte erhalten. R beginnt neu."
        case .differenceThreshold: "Negative Differenz: Hysterese oberhalb der Einschaltschwelle. Positive Differenz: Ein im Fenster von der Schwelle bis unter Schwelle + Differenz."
        case .toInteger: "Teilt Ax durch die Auflösung, rundet wie eingestellt und begrenzt auf den gewählten vorzeichenbehafteten Ganzzahlbereich."
        case .toFloat: "Multipliziert den ganzzahligen Anteil von Ax mit der Auflösung. Liefert einen Analogwert zur weiteren Verarbeitung."
        default: "\(title). Parameter, Anschlüsse und Negation rechts einstellen. R bedeutet Rücksetzen und hat Vorrang."
        }
    }
    public var descriptor: BlockDescriptor { .init(id: "plc." + rawValue, title: title, category: category, kind: .function, summary: summary, defaults: .object(Dictionary(uniqueKeysWithValues: [("function", ConfigValue.string(rawValue))] + parameters.map { ($0.key, $0.initial) })), requiredPaths: []) }
}
public extension Block {
    var function: PLCFunction? { kind == .function ? PLCFunction(rawValue: text("function")) : nil }
    var isGate: Bool { [.and, .or, .xor].contains(kind) || function.map { [.nand, .nor, .andEdge, .nandEdge].contains($0) } == true }
    var inputCount: Int {
        if function == .valueSelect { return valueSelectionCount }
        if isGate { let n = number("inputCount", kind == .function ? 5 : 2); return n.isFinite ? max(2, min(8, Int(n.clamped(to: 2...8)))) : 2 }
        if variableDuration { return 3 }
        if hasTimerReset { return 2 }
        return function?.pins.count ?? kind.inputCount
    }
    var outputType: SignalType { function.map { $0.analogOutput ? .analog : .digital } ?? kind.outputType }
    func inputType(_ pin: Int) -> SignalType { if variableDuration && pin == 2 { return .analog }; if let f = function { return f.pins.indices.contains(pin) ? f.pins[pin].1 : .digital }; return kind.inputType }
    var outputCount: Int { isGate || kind == .not ? 5 : function?.hasValueOutput == true ? 2 : kind.hasOutput ? 1 : 0 }
    func outputType(_ pin: Int) -> SignalType { function?.hasValueOutput == true && pin == 1 ? .analog : outputType }
    func outputLabel(_ pin: Int) -> String { function?.hasValueOutput == true && pin == 1 ? "AQ · Zahlenwert" : isGate || kind == .not ? "Q · Abgang \(pin + 1)" : outputType == .analog ? "AQ" : "Q" }
    func unusedDigitalInput(_ pin: Int) -> Bool? {
        if isGate { return kind == .and || function == .nand || function == .andEdge || function == .nandEdge }
        if function == .valueSelect { return false }
        if kind == .latch || hasTimerReset && pin == 1 { return false }
        if let f = function { return f.pins.indices.contains(pin) && f.pins[pin].1 == .digital ? ([.monitor, .pwm, .multiplexer].contains(f) && pin == (f == .multiplexer ? 0 : 1)) : nil }
        return nil
    }
}
private extension Double { func clamped(to r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, self)) } }
