import Foundation

public enum SignalType: String, Codable, Sendable { case digital, analog }
public extension BlockKind {
    var isPLC: Bool { [.function, .digitalInput, .analogInput, .digitalOutput, .analogOutput, .marker, .analogMarker, .markerContact, .analogContact, .analogCompare].contains(self) }
    var isMarker: Bool { self == .marker || self == .analogMarker }
    var isContact: Bool { self == .markerContact || self == .analogContact }
    var isPLCInput: Bool { self == .digitalInput || self == .analogInput }
    var isPLCOutput: Bool { self == .digitalOutput || self == .analogOutput }
    var outputType: SignalType { [.analogInput, .analogOutput, .analogMarker, .analogContact].contains(self) ? .analog : .digital }
    var inputType: SignalType { [.analogOutput, .analogMarker, .analogCompare].contains(self) ? .analog : .digital }
}
public extension Block {
    var virtualPLC: Bool { kind.isPLC && entityID.isEmpty }
    var markerID: UUID? { UUID(uuidString: text("markerID")) }
    var inputKey: String { entityID.isEmpty ? RuntimeCompiler.virtualInput(self) : entityID + (text("attribute").isEmpty ? "" : "#" + text("attribute")) }
    var initialInput: String { kind == .analogInput ? String(number("initial", 0)) : (flag("initial") ? "on" : "off") }
}
public extension AutomationGraph {
    var usesExtendedPLC: Bool { blocks.contains { $0.kind == .function || $0.options["inputCount"] != nil || $0.flag("resettable") || $0.options["priority"] != nil } || wires.contains { $0.output != 0 } }
    var usesPLCCycle: Bool { formatVersion >= 3 || usesExtendedPLC || blocks.contains { $0.kind.isPLC } }
    /// Named markers are scoped to a program. UUIDs are the stable identities.
    func nextMarkerName(analog: Bool) -> String {
        let prefix = analog ? "AM" : "M"
        let names = Set(blocks.filter { $0.kind.isMarker }.map(\.title))
        return (1...1000).map { prefix + String($0) }.first { !names.contains($0) } ?? prefix
    }
}

public extension AutomationGraph {
    static var plcExample: AutomationGraph {
        let set = Block(kind: .digitalInput, title: "Setzen", x: 60, y: 70)
        let reset = Block(kind: .digitalInput, title: "Rücksetzen", x: 60, y: 250)
        let relay = Block(kind: .latch, title: "Virtuelles Relais · RS", x: 370, y: 130)
        let marker = Block(kind: .marker, title: "M1 · Freigabe", x: 670, y: 130)
        let contact = Block(kind: .markerContact, title: "Kontakt · Freigabe", x: 370, y: 370, options: ["markerID": .string(marker.id.uuidString)])
        let output = Block(kind: .digitalOutput, title: "Virtueller Ausgang", x: 670, y: 370)
        return .init(title: "SPS · Relais und Merker", blocks: [set, reset, relay, marker, contact, output], wires: [
            .init(source: set.id, target: relay.id, input: 0), .init(source: reset.id, target: relay.id, input: 1),
            .init(source: relay.id, target: marker.id, input: 0), .init(source: contact.id, target: output.id, input: 0)
        ])
    }
}
