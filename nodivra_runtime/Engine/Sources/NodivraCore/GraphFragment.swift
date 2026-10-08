import Foundation

/// A clipboard selection carries internal connections, never links to omitted blocks.
public struct GraphFragment: Codable, Equatable, Sendable {
    public var format = "nodivra.selection"
    public var version = 1
    public var blocks: [Block]
    public var wires: [Wire]
    public init(graph: AutomationGraph, selection: Set<UUID>) {
        blocks = graph.blocks.filter { selection.contains($0.id) }
        wires = graph.wires.filter { selection.contains($0.source) && selection.contains($0.target) }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let fragment = try JSONDecoder().decode(Self.self, from: data)
        let ids = Set(fragment.blocks.map(\.id))
        guard fragment.format == "nodivra.selection", fragment.version == 1,
              !fragment.blocks.isEmpty, fragment.blocks.count <= 500, fragment.wires.count <= 2000,
              ids.count == fragment.blocks.count,
              Set(fragment.wires.map(\.id)).count == fragment.wires.count,
              fragment.blocks.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              fragment.wires.allSatisfy({ ids.contains($0.source) && ids.contains($0.target) })
        else { throw CocoaError(.fileReadCorruptFile) }
        return fragment
    }
    public func duplicated(dx: Double = 36, dy: Double = 36) -> Self {
        var result = self
        let mapping = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, UUID()) })
        result.blocks = blocks.map { block in
            var b = block; b.id = mapping[block.id]!; b.x += dx; b.y += dy; return b
        }
        result.wires = wires.map { .init(source: mapping[$0.source]!, target: mapping[$0.target]!, input: $0.input) }
        return result
    }
}
