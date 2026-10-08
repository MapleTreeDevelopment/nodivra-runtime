import Foundation

/// A flow output starts every connected branch. Each branch has its own condition scope.
public enum FlowCompiler {
    public static func isBranched(_ graph: AutomationGraph) -> Bool {
        let outgoing = Dictionary(grouping: graph.wires, by: \.source)
        let roots = graph.blocks.filter { $0.kind == .haTrigger }.map { (outgoing[$0.id] ?? []).map(\.target) }
        return outgoing.values.contains { $0.count > 1 } || roots.dropFirst().contains { $0 != roots.first }
    }
    public static func payload(_ block: Block, context: ImportContext?) -> ConfigValue {
        var value = block.configuration
        if block.negated { value = .object(["condition": .string("not"), "conditions": .array([value])]) }
        if context == nil || block.title != context?.originalTitles[block.id.uuidString] {
            if value.array != nil { value = .object(["condition": .string("and"), "conditions": value]) }
            else if value.object == nil { value = .object(["condition": .string("template"), "value_template": value]) }
            value = value.setting("alias", to: .string(block.title))
        }
        return value
    }
    public static func configuration(_ graph: AutomationGraph) throws -> ConfigValue {
        let context = graph.importContext
        let index = Dictionary(uniqueKeysWithValues: graph.blocks.map { ($0.id, $0) })
        let outgoing = Dictionary(grouping: graph.wires, by: \.source)
        func targets(_ id: UUID) -> [UUID] { (outgoing[id] ?? []).map(\.target) }
        let prior = context?.triggerIDs ?? []
        let triggers = prior.compactMap { index[$0] }.filter { $0.kind == .haTrigger } + graph.blocks.filter { $0.kind == .haTrigger && !prior.contains($0.id) }
        func parallel(_ branches: [[ConfigValue]]) -> [ConfigValue] {
            if branches.count == 1 { return branches[0] }
            return [.object(["parallel": .array(branches.map { .object(["sequence": .array($0)]) })])]
        }
        func sequence(_ id: UUID, visited: Set<UUID> = []) throws -> [ConfigValue] {
            guard let block = index[id], !visited.contains(id) else { throw CompilationError(diagnostics: [.init("Der Ablauf enthält eine Rückkopplung oder einen fehlenden Block.", blockID: id)]) }
            var seen = visited; seen.insert(id)
            let next = targets(id)
            return [payload(block, context: context)] + (next.isEmpty ? [] : try parallel(next.map { try sequence($0, visited: seen) }))
        }
        var config = context?.original.object ?? ["id": .string("nodivra_" + graph.id.uuidString.lowercased()), "mode": .string("single")]
        var triggerValues: [ConfigValue] = []
        for block in triggers where !block.flag("manualStart") {
            var value = payload(block, context: context)
            if context == nil, value.object?["id"] == nil { value = value.setting("id", to: .string(block.id.uuidString.lowercased())) }
            triggerValues.append(value)
        }
        let roots = triggers.map { targets($0.id) }
        var globals: [ConfigValue] = []
        let actions: [ConfigValue]
        if let first = roots.first, roots.allSatisfy({ $0 == first }) {
            var starts = first
            // Original global conditions remain global while they form the common prefix.
            while starts.count == 1, let block = index[starts[0]], block.text("importSection") == "conditions" {
                globals.append(payload(block, context: context)); starts = targets(block.id)
            }
            actions = try parallel(starts.map { try sequence($0) })
        } else {
            guard triggers.allSatisfy({ !$0.flag("manualStart") && $0.configuration.object?["triggers"] == nil }) else {
                throw CompilationError(diagnostics: [.init("Zusammengefasste oder manuelle Auslöser benötigen für getrennte Startpfade einen gemeinsamen ersten Baustein.")])
            }
            var groups: [([UUID], [Int])] = []
            for (i, ids) in roots.enumerated() {
                if let j = groups.firstIndex(where: { $0.0 == ids }) { groups[j].1.append(i) }
                else { groups.append((ids,[i])) }
            }
            actions = try parallel(groups.map { ids, positions in
                let condition: ConfigValue = .object(["condition": .string("template"), "value_template": .string("{{ trigger is defined and trigger.idx is defined and (trigger.idx | int) in [" + positions.map(String.init).joined(separator: ",") + "] }}")])
                return [condition] + (try parallel(ids.map { try sequence($0) }))
            })
        }
        func replace(_ plural: String, _ singular: String, _ values: [ConfigValue]) {
            let key = config[plural] != nil ? plural : config[singular] != nil ? singular : plural
            config[key] = .array(values)
        }
        replace("triggers", "trigger", triggerValues); replace("conditions", "condition", globals); replace("actions", "action", actions)
        config["alias"] = .string(graph.title)
        return .object(config)
    }
}
