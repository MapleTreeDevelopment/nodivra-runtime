import Foundation
import NodivraCore

struct Request: Decodable {
    var op: String
    var id: String?
    var package: RuntimePackage?
    var states: [String: String]?
    var now: Double?
    var date: Double?
    var commandID: UUID?
    var success: Bool?
    var checkpoint: RuntimeCheckpoint?
}
var engines: [String: RuntimeEngine] = [:]
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
func emit<T: Encodable>(_ value: T) { if let d = try? encoder.encode(value) { FileHandle.standardOutput.write(d + Data([10])) } }
while let line = readLine() {
    do {
        let r = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
        switch r.op {
        case "validate":
            guard let package = r.package else { throw CLIError.invalid }
            emit(RuntimeCompiler.validate(package))
        case "load":
            guard let package = r.package, let id = r.id, engines.count < 100 || engines[id] != nil else { throw CLIError.invalid }
            let date = Date(timeIntervalSince1970: r.date ?? Date().timeIntervalSince1970)
            if let saved = r.checkpoint { engines[id] = try RuntimeEngine(package: package, checkpoint: saved, states: r.states ?? [:], date: date) }
            else { engines[id] = try RuntimeEngine(package: package, states: r.states ?? [:], date: date) }
            emit(engines[id]!.snapshot())
        case "checkpoint":
            guard let id = r.id, let engine = engines[id] else { throw CLIError.invalid }
            emit(try engine.checkpoint())
        case "step":
            guard let id = r.id, var engine = engines[id], let now = r.now, let date = r.date else { throw CLIError.invalid }
            let result = engine.step(now: now, date: Date(timeIntervalSince1970: date), states: r.states ?? [:]); engines[id] = engine; emit(result)
        case "ack":
            guard let id = r.id, var engine = engines[id], let command = r.commandID, let success = r.success else { throw CLIError.invalid }
            engine.acknowledge(command, success: success); engines[id] = engine; emit(engine.snapshot())
        case "drop": if let id = r.id { engines.removeValue(forKey: id) }; emit(["ok": true])
        default: throw CLIError.invalid
        }
    } catch let error as CompilationError { emit(["error": error.diagnostics.map(\.message).joined(separator: " ")]) }
    catch { emit(["error": "Ungültige Engine-Anfrage."]) }
}
enum CLIError: Error { case invalid }
