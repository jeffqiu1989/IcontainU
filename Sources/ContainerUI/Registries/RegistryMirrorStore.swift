import ContainerizationOCI
import Foundation
import Observation

/// A single registry mirror mapping: pulls from `source` are rewritten to `mirror`.
struct RegistryMirror: Codable, Identifiable, Equatable {
    var id = UUID()
    var source: String
    var mirror: String
    var enabled: Bool = true
}

/// Stores user-defined registry mirror mappings and rewrites image references to
/// use them. This is a GUI-only acceleration layer: it rewrites references before
/// they are handed to `ClientImage.pull`, so it only affects pulls issued from the
/// GUI (not the CLI or implicit pulls during container creation).
@Observable
@MainActor
final class RegistryMirrorStore {
    /// Shared instance so the Images pull path and the Registries management UI
    /// operate on the same UserDefaults-backed mappings.
    static let shared = RegistryMirrorStore()

    private(set) var mirrors: [RegistryMirror] = []

    private let defaultsKey = "registryMirrors"

    /// Docker Hub's canonical domain, assumed for references without a domain.
    static let dockerHub = "docker.io"

    /// Built-in preset: DaoCloud (m.daocloud.io) prefix-style mirrors.
    static let daocloudPreset: [RegistryMirror] = [
        .init(source: "docker.io", mirror: "docker.m.daocloud.io"),
        .init(source: "gcr.io", mirror: "gcr.m.daocloud.io"),
        .init(source: "ghcr.io", mirror: "ghcr.m.daocloud.io"),
        .init(source: "k8s.gcr.io", mirror: "k8s-gcr.m.daocloud.io"),
        .init(source: "registry.k8s.io", mirror: "k8s.m.daocloud.io"),
        .init(source: "mcr.microsoft.com", mirror: "mcr.m.daocloud.io"),
        .init(source: "nvcr.io", mirror: "nvcr.m.daocloud.io"),
        .init(source: "quay.io", mirror: "quay.m.daocloud.io"),
        .init(source: "docker.elastic.co", mirror: "elastic.m.daocloud.io"),
    ]

    init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([RegistryMirror].self, from: data)
        else { return }
        mirrors = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(mirrors) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: Mutations

    func add(source: String, mirror: String) {
        let s = source.trimmingCharacters(in: .whitespaces)
        let m = mirror.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !m.isEmpty else { return }
        mirrors.append(RegistryMirror(source: s, mirror: m))
        save()
    }

    func remove(_ mirror: RegistryMirror) {
        mirrors.removeAll { $0.id == mirror.id }
        save()
    }

    func setEnabled(_ mirror: RegistryMirror, _ enabled: Bool) {
        guard let idx = mirrors.firstIndex(where: { $0.id == mirror.id }) else { return }
        mirrors[idx].enabled = enabled
        save()
    }

    /// Import the DaoCloud preset, skipping sources that already have a mapping.
    func importDaoCloudPreset() {
        let existing = Set(mirrors.map(\.source))
        for entry in Self.daocloudPreset where !existing.contains(entry.source) {
            mirrors.append(entry)
        }
        save()
    }

    // MARK: Rewrite

    /// Rewrite an image reference's registry domain to its mirror, if an enabled
    /// mapping exists. References without a domain are treated as Docker Hub.
    /// Returns the (possibly unchanged) reference.
    func rewrite(_ reference: String) -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard let parsed = try? Reference.parse(trimmed) else { return trimmed }

        // Determine the effective source domain.
        let sourceDomain = parsed.domain ?? Self.dockerHub

        guard
            let mapping = mirrors.first(where: {
                $0.enabled && $0.source.caseInsensitiveCompare(sourceDomain) == .orderedSame
            })
        else {
            return trimmed
        }

        // Rebuild: mirror domain + original path (+ tag/digest).
        // For Docker Hub sources, a bare path (no "/") needs the implicit
        // "library/" repository, since after rewriting the domain is no longer
        // docker.io and the normalizer would not add it.
        var path = parsed.path
        if sourceDomain.caseInsensitiveCompare(Self.dockerHub) == .orderedSame,
            !path.contains("/")
        {
            path = "library/\(path)"
        }

        var result = "\(mapping.mirror)/\(path)"
        if let tag = parsed.tag {
            result += ":\(tag)"
        } else if let digest = parsed.digest {
            result += "@\(digest)"
        }
        return result
    }
}
