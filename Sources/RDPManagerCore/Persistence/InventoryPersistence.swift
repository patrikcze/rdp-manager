import Foundation

/// Loads and saves the inventory.
public protocol InventoryPersistence: Sendable {
    func load() throws -> Inventory?
    func save(_ inventory: Inventory) throws
}

/// A JSON file, written atomically with owner-only permissions. Chosen over SwiftData/Core
/// Data: the inventory is a small document (thousands of rows load in milliseconds), it must
/// export and diff cleanly, and a plain file keeps migrations explicit and testable.
public struct JSONFileInventoryPersistence: InventoryPersistence {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/RDP Manager/inventory.json`
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appending(path: "RDP Manager", directoryHint: .isDirectory)
            .appending(path: "inventory.json", directoryHint: .notDirectory)
    }

    public func load() throws -> Inventory? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try InventoryMigrator.decode(data)
    }

    public func save(_ inventory: Inventory) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try InventoryMigrator.encoder.encode(inventory)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public struct InMemoryInventoryPersistence: InventoryPersistence {
    private let box = Box()

    public init(_ inventory: Inventory? = nil) {
        box.value = inventory
    }

    public func load() throws -> Inventory? {
        box.value
    }

    public func save(_ inventory: Inventory) throws {
        box.value = inventory
    }

    public var saved: Inventory? {
        box.value
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Inventory?
        var value: Inventory? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}

public enum InventoryMigrationError: Error, LocalizedError {
    case newerSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .newerSchema(version):
            "The connection library was saved by a newer version of RDP Manager (schema \(version))."
        }
    }
}

/// Reads any schema version this build knows and upgrades it to the current one.
public enum InventoryMigrator {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date \(text)"))
        }
        return decoder
    }()

    private struct VersionProbe: Decodable {
        var schemaVersion: Int
    }

    public static func decode(_ data: Data) throws -> Inventory {
        let version = try decoder.decode(VersionProbe.self, from: data).schemaVersion
        guard version <= Inventory.currentSchemaVersion else {
            throw InventoryMigrationError.newerSchema(version)
        }
        // 1 → 2: connections gained a protocol and SSH settings, folders SSH defaults and
        // credential profiles a kind. The models decode a version 1 file with the values
        // every version 1 item had (RDP, no SSH settings, RDP passwords), so the upgrade is
        // the decode itself; identifiers, references and history are kept as they are.
        var inventory = try decoder.decode(Inventory.self, from: data)
        inventory.schemaVersion = Inventory.currentSchemaVersion
        return inventory
    }
}
