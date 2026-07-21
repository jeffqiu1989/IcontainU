import Foundation
import Observation

/// Where a build config came from. Standalone configs are user-created and fully
/// editable; compose-derived configs are generated from a compose project's
/// `build:` services (read-only — the compose file owns them).
enum BuildSource: Codable, Equatable {
    case standalone
    case compose(project: String, service: String)

    /// The owning compose project, if any.
    var composeProject: String? {
        if case .compose(let project, _) = self { return project }
        return nil
    }
}

/// Snapshot of a finished build, persisted with its config so the card can show
/// the last outcome (and its log tail) across app restarts.
struct BuildOutcome: Codable, Equatable {
    enum Status: String, Codable {
        case succeeded
        case failed
    }

    var status: Status
    var startedAt: Date
    var duration: TimeInterval
    /// Failure message (empty on success).
    var message: String
    /// Last lines of the build log, capped at persistence time (200 lines) so
    /// `build.json` stays small.
    var logTail: [String]
}

/// Persistent record of a build configuration — one Dockerfile + context + tags
/// + options. The "build config card": create once, rebuild any time (the shared
/// builder's layer cache makes a rebuild after a code change fast).
struct BuildConfigRecord: Codable, Identifiable, Equatable {
    /// Unique config name; doubles as the card title and the storage directory.
    var name: String
    var contextDirPath: String
    var dockerfilePath: String
    /// Image tags the build produces (≥1 non-empty).
    var tags: [String]
    /// OCI platform strings, e.g. ["linux/arm64"]. Empty = host platform.
    var platforms: [String]
    var noCache: Bool
    /// "KEY=VALUE" build args.
    var buildArgs: [String]
    /// Target build stage; empty = final stage.
    var target: String
    /// "KEY=VALUE" image labels.
    var labels: [String]
    /// Always pull the base image (`--pull`).
    var pull: Bool
    var source: BuildSource
    var createdAt: Date
    /// Outcome of the most recent build, if any.
    var lastBuild: BuildOutcome?

    var id: String { name }

    var contextDir: URL { URL(fileURLWithPath: contextDirPath, isDirectory: true) }
    var dockerfile: URL { URL(fileURLWithPath: dockerfilePath) }

    var isComposeDerived: Bool {
        if case .compose = source { return true }
        return false
    }

    /// The primary display tag.
    var primaryTag: String { tags.first ?? name }
}

/// Stores build configs on disk, one directory per config under Application
/// Support — mirrors `ComposeProjectStore` (files, not UserDefaults, so a
/// config is easy to inspect and the log tail doesn't bloat defaults).
@Observable
@MainActor
final class BuildConfigStore {
    static let shared = BuildConfigStore()

    private(set) var records: [BuildConfigRecord] = []

    /// `~/Library/Application Support/IcontainU/builds/`.
    private let root: URL

    /// Lines of log tail persisted with an outcome.
    static let logTailLimit = 200

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = appSupport.appending(path: "IcontainU/builds", directoryHint: .isDirectory)
        }
        load()
    }

    // MARK: Load / persist

    /// Reload every config's `build.json` from disk, newest first.
    func load() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            records = []
            return
        }
        var loaded: [BuildConfigRecord] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let metaURL = dir.appending(path: "build.json")
            guard let data = try? Data(contentsOf: metaURL),
                let record = try? JSONDecoder.buildDecoder.decode(BuildConfigRecord.self, from: data)
            else { continue }
            loaded.append(record)
        }
        records = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    /// Persist (or overwrite) a config under `builds/<name>/build.json`.
    func save(_ record: BuildConfigRecord) throws {
        var capped = record
        if var outcome = capped.lastBuild, outcome.logTail.count > Self.logTailLimit {
            outcome.logTail = Array(outcome.logTail.suffix(Self.logTailLimit))
            capped.lastBuild = outcome
        }
        let dir = directory(for: capped.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder.buildEncoder.encode(capped)
        try data.write(to: dir.appending(path: "build.json"), options: .atomic)
        load()
    }

    /// Remove a config's record and its on-disk directory. Does not delete any
    /// built images — they stay in the local image store.
    func remove(config name: String) {
        try? FileManager.default.removeItem(at: directory(for: name))
        load()
    }

    func record(for name: String) -> BuildConfigRecord? {
        records.first { $0.name == name }
    }

    func exists(_ name: String) -> Bool {
        record(for: name) != nil
    }

    /// All compose-derived configs belonging to `project` — used to clean them up
    /// when the compose project is removed.
    func records(forComposeProject project: String) -> [BuildConfigRecord] {
        records.filter { $0.source.composeProject == project }
    }

    // MARK: Helpers

    private func directory(for name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }
}

extension JSONEncoder {
    /// ISO-8601 dates so `build.json` is human-readable.
    fileprivate static var buildEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    fileprivate static var buildDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
