import SwiftUI

/// Editable row models for the dynamic sections.
struct PortRow: Identifiable {
    let id = UUID()
    var hostPort: String = ""
    var containerPort: String = ""
    var proto: String = "tcp"

    /// CLI form "host:container/proto"; nil if incomplete.
    var cliValue: String? {
        guard !hostPort.isEmpty, !containerPort.isEmpty else { return nil }
        return "\(hostPort):\(containerPort)/\(proto)"
    }
}

struct EnvRow: Identifiable {
    let id = UUID()
    var key: String = ""
    var value: String = ""

    /// CLI form "KEY=VALUE"; nil if either side is blank so empty rows are dropped.
    var cliValue: String? {
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return "\(key)=\(value)"
    }
}

/// A mount row supporting both `container run -v` semantics: a named volume
/// (source is a volume name) or a bind mount (source is a host directory path).
/// The server distinguishes the two by whether the source contains a "/".
struct MountRow: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case volume = "Volume"
        case bind = "Bind"
        var id: String { rawValue }
    }

    let id = UUID()
    var kind: Kind = .volume
    /// Volume name (kind == .volume) or host path (kind == .bind).
    var source: String = ""
    var containerPath: String = ""
    var readOnly: Bool = false

    /// CLI form "source:dest[:ro]"; nil if either side is blank so the row is dropped.
    var cliValue: String? {
        let src = source.trimmingCharacters(in: .whitespaces)
        let dst = containerPath.trimmingCharacters(in: .whitespaces)
        guard !src.isEmpty, !dst.isEmpty else { return nil }
        return readOnly ? "\(src):\(dst):ro" : "\(src):\(dst)"
    }
}

/// Sentinel network selections that don't correspond to a named network.
enum NetworkSelection: Hashable {
    /// Attach to the built-in default network (don't pass --network).
    case `default`
    /// Disable networking (--network none).
    case none
    /// Attach to a specific named network.
    case named(String)
}

/// One network attachment row. A container may attach to several networks, so
/// these are editable like the port / env / mount rows.
struct NetworkRow: Identifiable {
    let id = UUID()
    var selection: NetworkSelection = .default
}

/// Form state holder for creating a container; pre-filled from image metadata.
/// Containers run detached. A command may be supplied to override the image
/// default (e.g. `sleep infinity` for a shell base image), but it is never
/// pre-filled — empty means "use the image default".
@Observable
@MainActor
final class CreateContainerFormState {
    var image = ""
    var name = ""
    /// Command override. Empty keeps the image default; non-empty is tokenized
    /// and passed as `arguments` (appended after any image entrypoint, exactly
    /// like `container run <image> <args...>`). Never pre-filled from the image —
    /// keeping it empty avoids round-tripping a default through tokenization.
    var command = ""
    // Ports and envs always keep at least one (possibly empty) row so the inline
    // `host : container  ⊖ ⊕` editor always shows a fillable row. Empty rows are
    // dropped at `makeSpec` time via their `cliValue`.
    var ports: [PortRow] = [PortRow()]
    var envs: [EnvRow] = [EnvRow()]
    var mounts: [MountRow] = [MountRow()]
    var networks: [NetworkRow] = [NetworkRow()]
    var autoRemove = false
    var ssh = false

    var analyzing = false

    /// Apply extracted image metadata as form defaults. Command/entrypoint and
    /// build-time env are intentionally ignored — the container runs the image
    /// default command, and baked-in env needs no user input.
    func apply(metadata: ImageMetadata) {
        // Ports: container port pre-filled, host left for the user.
        let mappedPorts = metadata.exposedPorts.map { spec -> PortRow in
            let parts = spec.split(separator: "/")
            return PortRow(
                hostPort: "",
                containerPort: String(parts.first ?? ""),
                proto: parts.count > 1 ? String(parts[1]) : "tcp")
        }
        ports = mappedPorts.isEmpty ? [PortRow()] : mappedPorts
        // Env: only the vars the entrypoint script expects the user to set
        // (e.g. MYSQL_ROOT_PASSWORD), keyed with empty values to fill in.
        let mappedEnvs = metadata.userEnv.map { EnvRow(key: $0, value: "") }
        envs = mappedEnvs.isEmpty ? [EnvRow()] : mappedEnvs
        // Volumes: container path pre-filled from VOLUME, source left for the user.
        let mappedMounts = metadata.volumes.map { MountRow(kind: .volume, source: "", containerPath: $0) }
        mounts = mappedMounts.isEmpty ? [MountRow()] : mappedMounts
    }

    /// Build the spec for the create engine.
    func makeSpec() -> ContainerCreateSpec {
        var spec = ContainerCreateSpec(image: image.trimmingCharacters(in: .whitespaces))
        spec.name = name.isEmpty ? nil : name
        spec.command = CommandTokenizer.tokenize(command)
        spec.publishPorts = ports.compactMap(\.cliValue)
        spec.env = envs.compactMap(\.cliValue)
        spec.volumes = mounts.compactMap(\.cliValue)
        // Map each row to a concrete network name. `.default` contributes nothing
        // (an empty list means "use the built-in default network"); `.none` and
        // named networks pass through. Duplicates are removed, order preserved.
        var seen = Set<String>()
        spec.networks = networks.compactMap { row -> String? in
            switch row.selection {
            case .default: return nil
            case .none: return "none"
            case .named(let name): return name
            }
        }
        .filter { seen.insert($0).inserted }
        spec.autoRemove = autoRemove
        spec.ssh = ssh
        return spec
    }
}
