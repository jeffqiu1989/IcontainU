import Foundation
import Observation

/// Persistent record of an imported compose project. The original YAML and the
/// declared resource names are stored so a project survives `down` (and app
/// restarts) and can be brought back up without re-selecting the file.
struct ComposeProjectRecord: Codable, Identifiable, Equatable {
    var name: String
    /// Original compose YAML text, verbatim.
    var yaml: String
    /// Directory the file was imported from, used to resolve relative bind mounts
    /// on a later Up. Nil when imported by pasting YAML.
    var baseDirectoryPath: String?
    /// Project-prefixed network names declared by the file.
    var declaredNetworks: [String]
    /// Project-prefixed volume names declared by the file.
    var declaredVolumes: [String]
    var importedAt: Date

    var id: String { name }

    var baseDirectory: URL? {
        baseDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

/// Stores imported compose projects on disk, one directory per project under
/// Application Support. Mirrors `RegistryMirrorStore`'s shared `@Observable`
/// pattern but persists to files (YAML can be large, and "one project per folder"
/// is easier to inspect) rather than UserDefaults.
@Observable
@MainActor
final class ComposeProjectStore {
    static let shared = ComposeProjectStore()

    private(set) var records: [ComposeProjectRecord] = []

    /// `~/Library/Application Support/IcontainU/compose/`.
    private let root: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = appSupport.appending(path: "IcontainU/compose", directoryHint: .isDirectory)
        load()
    }

    // MARK: Load / persist

    /// Reload every project's `project.json` from disk, newest import first.
    func load() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            records = []
            return
        }
        var loaded: [ComposeProjectRecord] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let metaURL = dir.appending(path: "project.json")
            guard let data = try? Data(contentsOf: metaURL),
                let record = try? JSONDecoder.composeDecoder.decode(ComposeProjectRecord.self, from: data)
            else { continue }
            loaded.append(record)
        }
        records = loaded.sorted { $0.importedAt > $1.importedAt }
    }

    /// Persist (or overwrite) a project. Writes `compose.yaml` + `project.json`
    /// under `compose/<name>/`.
    func save(_ record: ComposeProjectRecord) throws {
        let dir = directory(for: record.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try record.yaml.write(to: dir.appending(path: "compose.yaml"), atomically: true, encoding: .utf8)
        let data = try JSONEncoder.composeEncoder.encode(record)
        try data.write(to: dir.appending(path: "project.json"), options: .atomic)
        load()
    }

    /// Remove a project's record and its on-disk directory. Does not touch any
    /// running containers — call `ComposeEngine.down` first if needed.
    func remove(project name: String) {
        try? FileManager.default.removeItem(at: directory(for: name))
        load()
    }

    func record(for name: String) -> ComposeProjectRecord? {
        records.first { $0.name == name }
    }

    /// True when a project with this name is already stored — used to warn before
    /// overwriting on re-import.
    func exists(_ name: String) -> Bool {
        record(for: name) != nil
    }

    // MARK: Helpers

    private func directory(for name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }
}

extension JSONEncoder {
    /// ISO-8601 dates so `project.json` is human-readable.
    fileprivate static var composeEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    fileprivate static var composeDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
