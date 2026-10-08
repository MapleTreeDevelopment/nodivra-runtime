import Foundation

/// Logical identifiers survive renames and are scoped to a project and HA installation.
/// This is a read-only planner. Executing network writes is intentionally separate.
public enum HelperKind: String, Codable, Sendable {
    case boolean = "input_boolean", timer, counter, number = "input_number"
}

public struct HelperRequirement: Codable, Equatable, Sendable {
    public let key: UUID
    public let kind: HelperKind
    public let name: String
    public let areaID: String?
    public init(key: UUID, kind: HelperKind, name: String, areaID: String? = nil) {
        self.key = key; self.kind = kind; self.name = name; self.areaID = areaID
    }
}

public struct HelperBinding: Codable, Equatable, Sendable {
    public let logicalKey: UUID
    public let registryEntryID: String
    public let collectionItemID: String
    public let kind: HelperKind
    public init(logicalKey: UUID, registryEntryID: String, collectionItemID: String, kind: HelperKind) {
        self.logicalKey = logicalKey; self.registryEntryID = registryEntryID; self.collectionItemID = collectionItemID; self.kind = kind
    }
}

public struct DeploymentManifest: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let installationID: String
    public var bindings: [HelperBinding]
    public init(projectID: UUID, installationID: String, bindings: [HelperBinding] = []) {
        self.projectID = projectID; self.installationID = installationID; self.bindings = bindings
    }
}

public struct RegistryEntity: Equatable, Sendable {
    public let registryID: String
    public let entityID: String
    public let uniqueID: String
    public let platform: String
    public let disabled: Bool
    public init(registryID: String, entityID: String, uniqueID: String, platform: String, disabled: Bool = false) {
        self.registryID = registryID; self.entityID = entityID; self.uniqueID = uniqueID; self.platform = platform; self.disabled = disabled
    }
}

public enum HelperDecision: Equatable, Sendable {
    case create(HelperRequirement)
    case reuse(HelperRequirement, entityID: String)
}

public struct DeploymentPlanningError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum HelperPlanner {
    /// Never adopts a same-name helper or deletes anything. New IDs must be resolved
    /// from create responses and the entity registry before compiling final YAML.
    public static func plan(projectID: UUID, installationID: String, requirements: [HelperRequirement],
                            manifest: DeploymentManifest?, registry: [RegistryEntity]) throws -> [HelperDecision] {
        guard !installationID.isEmpty else { throw DeploymentPlanningError("Die Home-Assistant-Instanz ist nicht identifiziert.") }
        if let manifest, manifest.projectID != projectID || manifest.installationID != installationID {
            throw DeploymentPlanningError("Die Zuordnungen gehören zu einem anderen Projekt oder einer anderen Instanz.")
        }
        guard Set(requirements.map(\.key)).count == requirements.count,
              Set((manifest?.bindings ?? []).map(\.logicalKey)).count == (manifest?.bindings.count ?? 0),
              Set(registry.map(\.registryID)).count == registry.count else {
            throw DeploymentPlanningError("Mehrdeutige Helfer-Zuordnungen.")
        }
        return try requirements.map { requirement in
            guard !requirement.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeploymentPlanningError("Ein Helfer benötigt einen Namen.")
            }
            guard let binding = manifest?.bindings.first(where: { $0.logicalKey == requirement.key }) else { return .create(requirement) }
            guard binding.kind == requirement.kind else { throw DeploymentPlanningError("Helfertyp geändert: Eine Migration ist erforderlich.") }
            guard let entity = registry.first(where: { $0.registryID == binding.registryEntryID }) else {
                throw DeploymentPlanningError("Ein verwalteter Helfer fehlt. Bestand neu abgleichen, bevor ein Ersatz angelegt wird.")
            }
            guard entity.platform == requirement.kind.rawValue,
                  entity.uniqueID == binding.collectionItemID,
                  entity.entityID.hasPrefix(requirement.kind.rawValue + ".") else {
                throw DeploymentPlanningError("Die Identität eines verwalteten Helfers stimmt nicht mehr überein.")
            }
            guard !entity.disabled else { throw DeploymentPlanningError("Ein benötigter Helfer ist deaktiviert.") }
            return .reuse(requirement, entityID: entity.entityID)
        }
    }
}
