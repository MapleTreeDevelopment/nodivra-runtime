import Foundation

public enum BlockKind: String, Codable, CaseIterable, Sendable {
    case state, stateMatch, numeric, constant, timeWindow, button, and, or, xor, not, onDelay, offDelay, pulse, latch, output
    case haTrigger, haCondition, haAction
    case digitalInput, analogInput, digitalOutput, analogOutput, marker, analogMarker, markerContact, analogContact, analogCompare
    public var label: String {
        switch self {
        case .state: "Ein-/Aus-Zustand"; case .stateMatch: "Zustand vergleichen"; case .numeric: "Zahlenvergleich"
        case .timeWindow: "Zeitfenster"; case .constant: "Konstante"; case .button: "Taster / Schalter"; case .and: "UND"; case .or: "ODER"
        case .xor: "Exklusiv ODER"; case .not: "NICHT"; case .onDelay: "Einschaltverzögerung"
        case .offDelay: "Ausschaltverzögerung"; case .pulse: "Zeitimpuls"; case .latch: "Setzen / Rücksetzen"
        case .digitalInput: "Digitaler Eingang"; case .analogInput: "Analoger Eingang"
        case .digitalOutput: "Digitaler Ausgang"; case .analogOutput: "Analoger Ausgang"
        case .marker: "Merker"; case .analogMarker: "Analogmerker"
        case .markerContact: "Merkerkontakt"; case .analogContact: "Analogkontakt"
        case .analogCompare: "Analogwert vergleichen"
        case .output: "Schaltausgang"; case .haTrigger: "Auslöser"; case .haCondition: "Bedingung"; case .haAction: "Aktion"
        }
    }
    public var inputCount: Int {
        switch self {
        case .state, .stateMatch, .numeric, .constant, .timeWindow, .button, .haTrigger, .digitalInput, .analogInput, .markerContact, .analogContact: 0
        case .and, .or, .xor, .latch: 2
        default: 1
        }
    }
    public var isFlow: Bool { [.haTrigger, .haCondition, .haAction].contains(self) }
    public var hasOutput: Bool { self != .output }
    public var isTimed: Bool { [.onDelay, .offDelay, .pulse, .button].contains(self) }
    public var isMemory: Bool { [.onDelay, .offDelay, .pulse, .latch].contains(self) }
    public var isEntityInput: Bool { [.state, .stateMatch, .numeric, .button].contains(self) }
    public var icon: String {
        switch self {
        case .state, .stateMatch: "sensor"; case .numeric: "number"; case .constant: "number.square"; case .timeWindow: "clock"
        case .button: "button.programmable"; case .and: "arrow.triangle.merge"; case .or, .xor: "arrow.triangle.branch"
        case .not: "plus.forwardslash.minus"; case .onDelay, .offDelay: "timer"; case .pulse: "waveform.path"
        case .digitalInput, .analogInput: "arrow.right.square"
        case .digitalOutput, .analogOutput: "arrow.left.square"
        case .marker, .analogMarker, .markerContact, .analogContact: "memorychip"
        case .analogCompare: "number.circle"
        case .latch: "memorychip"; case .output: "lightbulb"; case .haTrigger: "bolt"
        case .haCondition: "line.3.horizontal.decrease.circle"; case .haAction: "play.square"
        }
    }
}
public struct Block: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: BlockKind
    public var title: String
    public var entityID: String
    public var x: Double
    public var y: Double
    public var notes: String
    public var negated: Bool
    public var negatedInputs: [Int]
    public var options: [String: ConfigValue]
    public var catalogID: String?
    public init(id: UUID = UUID(), kind: BlockKind, title: String, entityID: String = "", x: Double = 0, y: Double = 0,
                notes: String = "", negated: Bool = false, negatedInputs: [Int] = [], options: [String: ConfigValue] = [:], catalogID: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.entityID = entityID; self.x = x; self.y = y
        self.notes = notes; self.negated = negated; self.negatedInputs = negatedInputs; self.options = options; self.catalogID = catalogID
    }
    enum CodingKeys: String, CodingKey { case id, kind, title, entityID, x, y, notes, negated, negatedInputs, options, catalogID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); kind = try c.decode(BlockKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title); entityID = try c.decodeIfPresent(String.self, forKey: .entityID) ?? ""
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        negated = try c.decodeIfPresent(Bool.self, forKey: .negated) ?? false
        negatedInputs = try c.decodeIfPresent([Int].self, forKey: .negatedInputs) ?? []
        options = try c.decodeIfPresent([String: ConfigValue].self, forKey: .options) ?? [:]
        catalogID = try c.decodeIfPresent(String.self, forKey: .catalogID)
    }
    public func text(_ key: String, _ fallback: String = "") -> String { options[key]?.string ?? fallback }
    public func number(_ key: String, _ fallback: Double = 1) -> Double { options[key]?.number ?? fallback }
    public func flag(_ key: String, _ fallback: Bool = false) -> Bool { options[key]?.bool ?? fallback }
    public var duration: Double { number("duration", kind == .button ? 0.5 : 5) }
    public var managedButton: Bool { kind == .button && entityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var momentary: Bool { kind == .button && text("behavior", "momentary") == "momentary" }
    public var inputLabels: [String] { kind == .latch ? ["Setzen", "Rücksetzen"] : (0..<kind.inputCount).map { kind.isFlow ? "Signal / Start" : "Eingang \($0 + 1)" } }
    public var configuration: ConfigValue { options["configuration"] ?? .object([:]) }
}
public struct Wire: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var source: UUID
    public var target: UUID
    public var input: Int
    public init(source: UUID, target: UUID, input: Int, id: UUID = UUID()) { self.id = id; self.source = source; self.target = target; self.input = input }
}
public struct AutomationGraph: Codable, Equatable, Sendable {
    public var formatVersion = 2
    public var id: UUID
    public var title: String
    public var blocks: [Block]
    public var wires: [Wire]
    public var importContext: ImportContext?
    public init(id: UUID = UUID(), title: String, blocks: [Block], wires: [Wire]) { self.id = id; self.title = title; self.blocks = blocks; self.wires = wires; if blocks.contains(where: { $0.kind.isPLC }) { formatVersion = 3 } }
    /// Preserve native event sequences until a signal source/adapter is used.
    public var isFlow: Bool {
        !blocks.isEmpty && blocks.allSatisfy { $0.kind.isFlow } &&
        !blocks.contains { $0.text("signalBehavior") == "state" || $0.text("actionBehavior") != "" } &&
        blocks.filter { $0.kind == .haCondition }.allSatisfy { block in wires.contains { $0.target == block.id } }
    }
    public static var example: AutomationGraph {
        let a = Block(kind: .state, title: "Bewegung im Flur", entityID: "binary_sensor.flur_bewegung", x: 60, y: 80)
        let b = Block(kind: .state, title: "Es ist dunkel", entityID: "input_boolean.dunkel", x: 60, y: 290)
        let gate = Block(kind: .and, title: "Beides trifft zu", x: 370, y: 180)
        let light = Block(kind: .output, title: "Licht im Flur", entityID: "light.flur", x: 680, y: 180)
        return .init(title: "Licht im Flur", blocks: [a,b,gate,light], wires: [.init(source: a.id, target: gate.id, input: 0),.init(source: b.id, target: gate.id, input: 1),.init(source: gate.id, target: light.id, input: 0)])
    }
    public static var buttonExample: AutomationGraph {
        let a = Block(kind: .button, title: "Virtueller Taster", x: 60, y: 150, options: ["duration": .number(0.8)])
        let b = Block(kind: .offDelay, title: "Licht nachlaufen lassen", x: 370, y: 150, options: ["duration": .number(5)])
        let c = Block(kind: .output, title: "Licht im Flur", entityID: "light.flur", x: 680, y: 150)
        return .init(title: "Taster mit Nachlauf", blocks: [a,b,c], wires: [.init(source: a.id, target: b.id, input: 0),.init(source: b.id, target: c.id, input: 0)])
    }
    public static var sunsetExample: AutomationGraph {
        var sun = BlockCatalog.descriptors.first { $0.id == "trigger.sun" }!.makeBlock()
        var early = BlockCatalog.descriptors.first { $0.id == "condition.time" }!.makeBlock()
        var late = early; late.id = UUID()
        var bright = BlockCatalog.descriptors.first { $0.id == "action.service" }!.makeBlock()
        var dimmed = bright; dimmed.id = UUID()
        sun.x = 50; sun.y = 200
        early.title = "Vor 20 Uhr"; early.x = 390; early.y = 70; early.options["configuration"] = .object(["condition":.string("time"),"before":.string("20:00:00")])
        late.title = "Ab 20 Uhr"; late.x = 390; late.y = 360; late.options["configuration"] = .object(["condition":.string("time"),"after":.string("20:00:00")])
        bright.title = "Küchenlicht · 70 %"; bright.x = 740; bright.y = 70
        bright.options["configuration"] = .object(["action":.string("light.turn_on"),"target":.object(["entity_id":.string("light.kuche")]),"data":.object(["brightness_pct":.number(70)])])
        dimmed.title = "Küchenlicht · 25 %"; dimmed.x = 740; dimmed.y = 360
        dimmed.options["configuration"] = bright.configuration.setting("data",to:.object(["brightness_pct":.number(25)]))
        return .init(title:"Sonnenuntergang · zwei Zeitfenster",blocks:[sun,early,late,bright,dimmed],wires:[.init(source:sun.id,target:early.id,input:0),.init(source:sun.id,target:late.id,input:0),.init(source:early.id,target:bright.id,input:0),.init(source:late.id,target:dimmed.id,input:0)])
    }
    public static var nightMotionExample: AutomationGraph {
        let motion = Block(kind: .state, title: "Bewegung erkannt", entityID: "binary_sensor.bewegung", x: 50, y: 70, catalogID: "logic.motion")
        let night = Block(kind: .timeWindow, title: "Nachts · 22 bis 6 Uhr", x: 50, y: 280)
        let gate = Block(kind: .and, title: "Bewegung UND nachts", x: 340, y: 160)
        let delay = Block(kind: .offDelay, title: "5 Minuten Nachlauf", x: 630, y: 160, options: ["duration": .number(300)])
        let light = Block(kind: .output, title: "Küchenbeleuchtung", entityID: "light.kuche", x: 920, y: 160)
        return .init(title: "Bewegung nachts · 5 Minuten Nachlauf", blocks: [motion, night, gate, delay, light], wires: [
            .init(source: motion.id, target: gate.id, input: 0), .init(source: night.id, target: gate.id, input: 1),
            .init(source: gate.id, target: delay.id, input: 0), .init(source: delay.id, target: light.id, input: 0)
        ])
    }
    public static var flowExample: AutomationGraph {
        var a = BlockCatalog.descriptors.first { $0.id == "trigger.time" }!.makeBlock()
        var b = BlockCatalog.descriptors.first { $0.id == "action.service" }!.makeBlock()
        a.x = 60; a.y = 150; b.x = 390; b.y = 150
        return .init(title: "Abendbeleuchtung", blocks: [a,b], wires: [.init(source: a.id, target: b.id, input: 0)])
    }
}
public struct Diagnostic: Identifiable, Equatable, Sendable {
    public var id: String { "\(blockID?.uuidString ?? "graph"):\(message)" }
    public var blockID: UUID?
    public var message: String
    public init(_ message: String, blockID: UUID? = nil) { self.message = message; self.blockID = blockID }
}
public struct CompilationError: Error, Sendable { public let diagnostics: [Diagnostic] }
