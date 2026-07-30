import Foundation

public enum ProjectStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case notAPackage(URL)
}

public enum ManifestMigrator {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Decodes any supported schema version, migrating forward to current.
    public static func load(from data: Data) throws -> ProjectManifest {
        struct VersionProbe: Decodable { let schemaVersion: Int }
        let version = (try? decoder.decode(VersionProbe.self, from: data))?.schemaVersion ?? -1
        switch version {
        case 1:
            return try decoder.decode(ProjectManifest.self, from: data)
            // Future: case 2 — decode v2 struct, map down/up here.
        default:
            throw ProjectStoreError.unsupportedSchema(version)
        }
    }

    public static func save(_ manifest: ProjectManifest) throws -> Data {
        try encoder.encode(manifest)
    }
}
