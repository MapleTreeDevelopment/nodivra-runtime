import Foundation

public enum GraphValidator {
    public static func validate(_ graph: AutomationGraph) -> [Diagnostic] {
        var issues: [Diagnostic] = []
        guard [1,2].contains(graph.formatVersion) else { return [.init("Diese Projektversion wird nicht unterstützt.")] }
        guard graph.blocks.count <= 500, graph.wires.count <= 2000 else { return [.init("Das Projekt überschreitet die unterstützte Größe.")] }
        guard Set(graph.blocks.map(\.id)).count == graph.blocks.count else { return [.init("Block-IDs sind nicht eindeutig.")] }
        guard Set(graph.wires.map(\.id)).count == graph.wires.count else { return [.init("Verbindungs-IDs sind nicht eindeutig.")] }
        let index = Dictionary(uniqueKeysWithValues: graph.blocks.map { ($0.id, $0) })
        if graph.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.init("Die Automation benötigt einen Namen.")) }
        if graph.blocks.isEmpty { return issues + [.init("Füge Bausteine hinzu.")] }
        if graph.importContext?.original.object?["use_blueprint"] != nil {
            guard graph.blocks.count == 1, graph.blocks[0].flag("blueprint"), graph.wires.isEmpty,
                  graph.blocks[0].configuration.object?["use_blueprint"]?.object?["path"]?.string?.isEmpty == false else {
                return [.init("Ein Blueprint benötigt einen gültigen Pfad und seinen Eingabeblock.")]
            }
            return graph.blocks[0].flag("configurationError") ? [.init("Die Blueprint-Konfiguration enthält ungültiges JSON.")] : []
        }
        for block in graph.blocks {
            func issue(_ message: String) { issues.append(.init(message, blockID: block.id)) }
            if !block.x.isFinite || !block.y.isFinite { issue("Ungültige Blockposition.") }
            if block.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issue("Bitte eine Bezeichnung eintragen.") }
            if block.negatedInputs.contains(where: { $0 < 0 || $0 >= block.kind.inputCount }) { issue("Ungültiger negierter Eingang.") }
            if block.kind == .timeWindow && !TimeWindow(block: block).valid { issue("Wähle gültige Uhrzeiten (Minutengenauigkeit), mindestens einen Wochentag und unterschiedliche Grenzen oder Ganztägig.") }
            if block.kind.isTimed && (!block.duration.isFinite || block.duration < 0.1 || block.duration > 86400) { issue("Die Dauer muss zwischen 0,1 Sekunden und 24 Stunden liegen.") }
            if block.kind == .button && !["momentary", "switch"].contains(block.text("behavior", "momentary")) { issue("Ungültiges Tasterverhalten.") }
            if block.kind == .output && !["follow", "on", "off", "toggle"].contains(block.text("behavior", "follow")) { issue("Ungültiges Ausgangsverhalten.") }
            if block.kind.isTimed && !["restart", "ignore"].contains(block.text("retrigger", "restart")) { issue("Ungültiges Verhalten bei erneutem Auslösen.") }
            if block.kind == .numeric && ![">",">=","<","<=","==","!="].contains(block.text("comparison", ">")) { issue("Ungültiger Vergleichsoperator.") }
            if block.kind == .numeric && !block.number("threshold", 20).isFinite { issue("Der Schwellwert muss eine endliche Zahl sein.") }
            if block.kind.isEntityInput && !block.managedButton || block.kind == .output {
                if block.entityID.range(of: "^[a-z_]+\\.[a-z0-9_]+$", options: .regularExpression) == nil { issue("Eine gültige Entität im Format domain.name wird benötigt.") }
                let domain = block.entityID.split(separator: ".").first.map(String.init) ?? ""
                if block.kind == .state && !["binary_sensor","input_boolean","switch","light","fan"].contains(domain) { issue("Dieser Eingang benötigt eine Entität mit on/off-Zustand. Verwende sonst einen Zustandsvergleich.") }
                if block.kind == .output && !["light","switch","input_boolean","fan"].contains(domain) { issue("Der Schaltausgang unterstützt light, switch, input_boolean und fan.") }
                if block.kind == .button && !["switch","input_boolean","light","fan"].contains(domain) { issue("Ein rücksetzbarer Taster benötigt eine schaltbare Entität; binary_sensor ist nur lesbar.") }
            }
            if block.kind.isFlow {
                let shorthand = block.kind == .haCondition && (block.configuration.string != nil || block.configuration.bool != nil || block.configuration.array != nil)
                guard let config = block.configuration.object ?? (shorthand ? [:] : nil) else { issue("Die HA-Konfiguration muss ein Objekt oder eine Template-Bedingung sein."); continue }
                let root = block.kind == .haTrigger ? "trigger" : block.kind == .haCondition ? "condition" : nil
                let shortLogic = block.kind == .haCondition && ["and","or","not"].contains(where: { config[$0] != nil })
                if let root, !shorthand && !shortLogic && config["triggers"]?.array == nil, (config[root] ?? (root == "trigger" ? config["platform"] : nil))?.string?.isEmpty != false { issue("Das Feld \(root) fehlt.") }
                if block.kind == .haAction && config.isEmpty { issue("Die Konfiguration enthält keine unterstützte HA-Aktionsstruktur.") }
                for path in BlockCatalog.descriptor(for: block)?.requiredPaths ?? [] {
                    let item = path.split(separator: ".").reduce(Optional(block.configuration)) { $0?.object?[String($1)] }
                    if item == nil || item == .null || item?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "" || item?.array?.isEmpty == true { issue("Pflichtfeld fehlt: \(path)") }
                }
                if block.options["configurationError"] != nil { issue("Die erweiterte Konfiguration enthält ungültiges JSON.") }
                if graph.isFlow && block.negated && block.kind != .haCondition { issue("Nur Bedingungen lassen sich negieren; Ereignisse und Aktionen nicht.") }
                if graph.isFlow && !block.negatedInputs.isEmpty { issue("Ein Ablaufanschluss ist kein boolesches Signal.") }
            }
            for pin in 0..<block.kind.inputCount {
                let incoming = graph.wires.filter { $0.target == block.id && $0.input == pin }
                let triggerMerge = block.kind.isFlow && !incoming.isEmpty && incoming.allSatisfy { index[$0.source]?.kind == .haTrigger }
                if incoming.isEmpty && !(block.kind == .haCondition && !graph.isFlow) { issue("\(block.inputLabels[pin]) ist nicht verbunden.") }
                else if incoming.count > 1 && !triggerMerge { issue("Eingang \(pin + 1) ist mehrfach verbunden.") }
            }
            if block.kind.isFlow {
                let outgoing = graph.wires.filter { $0.source == block.id }
                if block.kind == .haTrigger && outgoing.isEmpty { issue("Der Auslöser ist mit keinem Ablauf verbunden.") }
                if block.configuration.object?["stop"] != nil && !outgoing.isEmpty { issue("Nach einem Stopp kann keine weitere Aktion folgen.") }
            }
        }
        for wire in graph.wires {
            guard let a = index[wire.source], let b = index[wire.target] else { issues.append(.init("Verbindung verweist auf einen fehlenden Block.")); continue }
            if !a.kind.hasOutput { issues.append(.init("Ein Schaltausgang kann kein Signal liefern.", blockID: a.id)) }
            if wire.input < 0 || wire.input >= b.kind.inputCount { issues.append(.init("Verbindung verwendet einen ungültigen Eingang.", blockID: b.id)) }
        }
        var visiting = Set<UUID>(), visited = Set<UUID>()
        func visit(_ id: UUID) -> Bool {
            if visiting.contains(id) { return true }; if visited.contains(id) { return false }
            visiting.insert(id)
            for w in graph.wires where w.target == id { if visit(w.source) { return true } }
            visiting.remove(id); visited.insert(id); return false
        }
        if graph.blocks.contains(where: { visit($0.id) }) { issues.append(.init("Rückkopplung: Benutze für Speicher oder Wiederholung einen entsprechenden Baustein.")) }
        let outputs = graph.blocks.filter { $0.kind == .output }
        if graph.isFlow {
            if !graph.blocks.contains(where: { $0.kind == .haTrigger }) { issues.append(.init("Der Ablauf benötigt mindestens einen Auslöser.")) }
            if !graph.blocks.contains(where: { $0.kind == .haAction }) { issues.append(.init("Der Ablauf benötigt mindestens eine Aktion.")) }
        } else {
            if outputs.isEmpty && !graph.blocks.contains(where: { $0.kind == .haAction }) { issues.append(.init("Verbinde das Netz mit einer Aktion oder einem Schaltausgang.")) }
            if Set(outputs.map(\.entityID)).count != outputs.count { issues.append(.init("Mehrere Ausgänge steuern dieselbe Entität.")) }
            let inputs = Set(graph.blocks.filter { $0.kind.isEntityInput && !$0.managedButton }.map(\.entityID))
            for output in outputs where inputs.contains(output.entityID) { issues.append(.init("Ausgang ist zugleich Eingang: mögliche Selbst-Auslösung.", blockID: output.id)) }
            let buttons = graph.blocks.filter { $0.kind == .button && !$0.managedButton }
            if Set(buttons.map(\.entityID)).count != buttons.count { issues.append(.init("Eine Entität kann nur durch einen Tasterblock zurückgesetzt werden.")) }
        }
        if issues.isEmpty {
            var reachable = Set<UUID>()
            func mark(_ id: UUID) {
                guard reachable.insert(id).inserted else { return }
                let next = graph.wires.filter { graph.isFlow ? $0.source == id : $0.target == id }
                for wire in next { mark(graph.isFlow ? wire.target : wire.source) }
            }
            for block in graph.blocks where graph.isFlow ? block.kind == .haTrigger : (block.kind == .output || block.kind == .haAction) { mark(block.id) }
            for block in graph.blocks where !reachable.contains(block.id) { issues.append(.init("Dieser Block hat keinen Einfluss auf die Automation.", blockID: block.id)) }
        }
        if !graph.isFlow { issues += SignalBridge.diagnostics(graph) }
        return issues
    }
}
