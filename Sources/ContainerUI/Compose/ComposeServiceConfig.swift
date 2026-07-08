import Foundation
import SwiftUI

/// Editable form state for a single compose service. Converts between the decoded
/// `ComposeService` (string-based YAML representation) and the row-model form
/// (`PortRow`, `EnvRow`, `MountRow`, `NetworkRow`) used by the UI editors.
@Observable
@MainActor
final class ComposeServiceConfig: Identifiable {
    let id: String  // original YAML service name (stable key)

    /// The YAML service name. Not editable — it's the DNS name used by other
    /// services and by /etc/hosts injection. Changing it would break inter-service
    /// connectivity; to rename, edit the YAML and re-analyze.
    let serviceName: String

    var image: String
    /// Resolved container name. Defaults to `<project>-<service>`; user can override.
    var containerName: String
    /// The container name as first loaded; `containerNameOverridden` compares against
    /// it so the "edited" pencil reflects a real user change, not the default.
    let originalContainerName: String
    /// True when the user manually edited `containerName` away from its loaded value.
    var containerNameOverridden: Bool { containerName != originalContainerName }

    var command: String  // space-joined for display; tokenized on makeSpec
    var ports: [PortRow]
    var envs: [EnvRow]
    var mounts: [MountRow]
    var networks: [NetworkRow]
    var user: String

    // Read-only display fields (from the decoded YAML, not editable in the form).
    var dependsOn: [String]
    var dependsOnConditions: [String: String]
    var healthcheck: ComposeHealthcheck?
    var ignored: [String]

    /// UI accordion toggle.
    var isExpanded: Bool = true

    init(
        serviceName: String,
        image: String,
        containerName: String,
        command: String,
        ports: [PortRow],
        envs: [EnvRow],
        mounts: [MountRow],
        networks: [NetworkRow],
        user: String,
        dependsOn: [String],
        dependsOnConditions: [String: String],
        healthcheck: ComposeHealthcheck?,
        ignored: [String]
    ) {
        self.id = serviceName
        self.serviceName = serviceName
        self.image = image
        self.containerName = containerName
        self.originalContainerName = containerName
        self.command = command
        self.ports = ports
        self.envs = envs
        self.mounts = mounts
        self.networks = networks
        self.user = user
        self.dependsOn = dependsOn
        self.dependsOnConditions = dependsOnConditions
        self.healthcheck = healthcheck
        self.ignored = ignored
    }

    /// Build a `ComposeServiceConfig` from a decoded `ComposeService`, parsing
    /// the string-based fields into the row models the form editors expect.
    ///
    /// - Parameters:
    ///   - name: The YAML service key (e.g. "db").
    ///   - service: The decoded service.
    ///   - defaultContainerName: Auto-derived container name (`<project>-<service>`).
    static func from(
        name: String,
        service: ComposeService,
        defaultContainerName: String
    ) -> ComposeServiceConfig {
        ComposeServiceConfig(
            serviceName: name,
            image: service.image ?? "",
            containerName: service.containerName ?? defaultContainerName,
            command: CommandTokenizer.join(service.command),
            ports: Self.parsePorts(service.ports),
            envs: Self.parseEnv(service.environment),
            mounts: Self.parseVolumes(service.volumes),
            networks: Self.parseNetworks(service.networks),
            user: service.user ?? "",
            dependsOn: service.dependsOn,
            dependsOnConditions: service.dependsOnConditions,
            healthcheck: service.healthcheck,
            ignored: service.ignored
        )
    }

    /// Convert the edited form state back to a `ContainerCreateSpec` for the
    /// create engine. Named volumes and networks are project-prefixed here; bind
    /// mount host paths are resolved to absolute paths against `baseDirectory`
    /// (the compose file's directory), matching docker compose semantics.
    func makeSpec(project: String, serviceLabel: String, baseDirectory: URL?) throws -> ContainerCreateSpec {
        var spec = ContainerCreateSpec(image: image.trimmingCharacters(in: .whitespaces))
        spec.name = containerName.isEmpty ? nil : containerName
        spec.command = CommandTokenizer.tokenize(command)
        spec.publishPorts = ports.compactMap(\.cliValue)
        spec.env = envs.compactMap(\.cliValue)

        // Resolve each mount to a "source:target[:ro]" entry: named volumes get the
        // project prefix; bind host paths are resolved to an absolute path so the
        // engine (which has no notion of the compose file's directory) can find them.
        spec.volumes = try mounts.compactMap { mount -> String? in
            let target = mount.containerPath.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            let source: String
            switch mount.kind {
            case .volume:
                let name = mount.volumeName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                source = "\(project)_\(name)"
            case .bind:
                let path = mount.bindPath.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return nil }
                source = try Self.resolveBindPath(path, service: serviceName, baseDirectory: baseDirectory)
            }
            return mount.readOnly ? "\(source):\(target):ro" : "\(source):\(target)"
        }

        // Resolve networks with project prefix. If no networks are selected,
        // leave empty (engine uses default network).
        var seen = Set<String>()
        spec.networks = networks.compactMap { row -> String? in
            switch row.selection {
            case .default: return nil
            case .none: return "none"
            case .named(let name): return "\(project)_\(name)"
            }
        }
        .filter { seen.insert($0).inserted }

        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        spec.user = trimmedUser.isEmpty ? nil : trimmedUser
        spec.labels = [
            ComposeFile.projectLabel: project,
            ComposeFile.serviceLabel: serviceLabel,
        ]
        return spec
    }

    /// Build a diff against the original `ComposeService` for persistence as a
    /// `ServiceOverride`. Only fields that actually changed are populated.
    func buildOverride(original: ComposeService, project: String) -> ServiceOverride? {
        var override = ServiceOverride()
        var changed = false

        // Container name: changed if different from the YAML default
        let defaultName = original.containerName ?? "\(project)-\(serviceName)"
        if containerName != defaultName {
            override.containerName = containerName
            changed = true
        }

        if image != (original.image ?? "") {
            override.image = image
            changed = true
        }

        let originalCommand = CommandTokenizer.join(original.command)
        if command != originalCommand {
            override.command = CommandTokenizer.tokenize(command)
            changed = true
        }

        let currentPorts = ports.compactMap(\.cliValue)
        if currentPorts != original.ports {
            override.publishPorts = currentPorts
            changed = true
        }

        let currentEnv = envs.compactMap(\.cliValue)
        if currentEnv != original.environment {
            override.env = currentEnv
            changed = true
        }

        // Volumes: compare against the original YAML values (before prefix resolution).
        let currentVolumes = mounts.compactMap { $0.cliValue }
        if currentVolumes != original.volumes {
            override.volumes = currentVolumes
            changed = true
        }

        // Networks: compare against the original YAML values (before prefix).
        let currentNetworks = networks.compactMap { row -> String? in
            if case .named(let name) = row.selection { return name }
            return nil
        }
        if currentNetworks != original.networks {
            override.networks = currentNetworks
            changed = true
        }

        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        if trimmedUser != (original.user ?? "") {
            override.user = trimmedUser.isEmpty ? nil : trimmedUser
            changed = true
        }

        return changed ? override : nil
    }

    // MARK: - Parsing helpers

    /// Resolve a bind mount host path to an absolute path, mirroring
    /// `ComposeFile.resolveVolume`: absolute paths pass through, `~` expands to the
    /// home directory, and a relative path is resolved against `baseDirectory` (the
    /// compose file's directory). Relative paths without a base directory can't be
    /// resolved — the same error the non-editable Up path raises.
    private static func resolveBindPath(
        _ source: String, service: String, baseDirectory: URL?
    ) throws -> String {
        if source.hasPrefix("/") {
            return source
        }
        if source.hasPrefix("~") {
            return (source as NSString).expandingTildeInPath
        }
        guard let base = baseDirectory else {
            throw ComposeError.relativeBindWithoutBaseDirectory(service: service, source: source)
        }
        return URL(fileURLWithPath: source, relativeTo: base).standardizedFileURL.path
    }

    private static func parsePorts(_ raw: [String]) -> [PortRow] {
        // No placeholder fallback: an empty result hides the section in the editor.
        raw.map { entry -> PortRow in
            // "host:container/proto" — already normalized by ComposeService.normalizePort
            let (mapping, proto) = splitProto(entry)
            let parts = mapping.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return PortRow(hostPort: parts[0], containerPort: parts[1], proto: proto)
            }
            return PortRow(hostPort: mapping, containerPort: mapping, proto: proto)
        }
    }

    private static func parseEnv(_ raw: [String]) -> [EnvRow] {
        raw.map { entry -> EnvRow in
            if let eq = entry.firstIndex(of: "=") {
                let key = String(entry[entry.startIndex..<eq])
                let value = String(entry[entry.index(after: eq)...])
                return EnvRow(key: key, value: value)
            }
            return EnvRow(key: entry, value: "")
        }
    }

    private static func parseVolumes(_ raw: [String]) -> [MountRow] {
        raw.map { entry -> MountRow in
            let parts = entry.split(separator: ":", maxSplits: 2).map(String.init)
            let source = parts.first ?? ""
            let target = parts.count >= 2 ? parts[1] : ""
            let mode = parts.count >= 3 ? parts[2] : nil
            let kind: MountRow.Kind = source.contains("/") || source.hasPrefix("~") ? .bind : .volume
            return MountRow(
                kind: kind,
                volumeName: kind == .volume ? source : "",
                bindPath: kind == .bind ? source : "",
                containerPath: target,
                readOnly: mode == "ro")
        }
    }

    private static func parseNetworks(_ raw: [String]) -> [NetworkRow] {
        raw.map { NetworkRow(selection: .named($0)) }
    }

    private static func splitProto(_ raw: String) -> (mapping: String, proto: String) {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (parts[0], parts[1]) }
        return (raw, "tcp")
    }
}
