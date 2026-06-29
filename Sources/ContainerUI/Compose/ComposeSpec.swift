import Foundation
import Yams

/// A parsed Compose file (the supported subset) plus the logic to turn it into the
/// `ContainerCreateSpec`s the existing create engine consumes.
///
/// Design notes:
///   - Service discovery requires the container's resolvable name to equal the
///     compose service name (the underlying runtime has no network aliases), so a
///     container is named `container_name ?? <serviceName>` with NO project prefix.
///     The trade-off — two projects with the same service name can't run at once —
///     is surfaced in the UI.
///   - Named volumes and networks DO get a `<project>_` prefix so projects don't
///     clobber each other's shared resources.
///   - Several real-world fields are polymorphic in YAML (string|array, list|map,
///     int|string); the custom decoders below accept every form the awesome-compose
///     examples use.

// MARK: - Errors

enum ComposeError: LocalizedError {
    case empty
    case noServices
    case dependencyCycle([String])
    case relativeBindWithoutBaseDirectory(service: String, source: String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The compose file is empty."
        case .noServices:
            return "The compose file declares no services."
        case .dependencyCycle(let names):
            return "depends_on forms a cycle: \(names.joined(separator: " → "))."
        case .relativeBindWithoutBaseDirectory(let service, let source):
            return
                "Service \"\(service)\" uses a relative bind mount \"\(source)\" that must be "
                + "resolved against the compose file's directory. Import the project by choosing "
                + "the file (not by pasting YAML) so the path can be resolved."
        }
    }
}

// MARK: - Scalar (string | int | double | bool)

/// Decodes a YAML scalar that may be a string, integer, double, or bool into its
/// string form. YAML reads `5432` and `3000:3000`'s left side as integers, and
/// `environment` values are frequently unquoted numbers/bools, so every scalar we
/// care about funnels through here.
struct ComposeScalar: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int.self) {
            value = String(i)
        } else if let d = try? c.decode(Double.self) {
            // Avoid "3.0" for whole numbers that slipped through as Double.
            value = d == d.rounded() ? String(Int(d)) : String(d)
        } else if let b = try? c.decode(Bool.self) {
            value = b ? "true" : "false"
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported scalar value")
        }
    }
}

// MARK: - Top level

struct ComposeFile: Decodable {
    var services: [String: ComposeService]
    /// Top-level named networks. Values may be null (`appnet:`) or a mapping whose
    /// fields we ignore, so the value is a permissive optional.
    var networks: [String: ComposeResourceDef?]?
    var volumes: [String: ComposeResourceDef?]?
}

/// A top-level network/volume definition. We only need the key (its name); any
/// fields (driver, internal, …) are intentionally ignored for this subset.
struct ComposeResourceDef: Decodable {}

// MARK: - Service

struct ComposeService: Decodable {
    var image: String?
    var containerName: String?
    var command: [String]
    var environment: [String]
    var ports: [String]
    var volumes: [String]
    var networks: [String]
    var dependsOn: [String]
    /// Run the container as this user — compose `user:` (a string like "0",
    /// "1000:1000", or "mysql"). YAML numbers are accepted.
    var user: String?
    /// Known-but-unsupported fields that were present, for the UI warning banner.
    var ignored: [String]

    private enum CodingKeys: String, CodingKey {
        case image
        case containerName = "container_name"
        case command
        case environment
        case ports
        case volumes
        case networks
        case dependsOn = "depends_on"
        case expose
        case user
        // Known but unsupported — presence is reported, value ignored.
        case build
        case healthcheck
        case restart
        case deploy
        case profiles
        case secrets
        case configs
        case envFile = "env_file"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        image = try c.decodeIfPresent(String.self, forKey: .image)
        containerName = try c.decodeIfPresent(String.self, forKey: .containerName)

        // command: "string" | [args]
        if let array = try? c.decode([ComposeScalar].self, forKey: .command) {
            command = array.map(\.value)
        } else if let line = try? c.decode(String.self, forKey: .command) {
            command = CommandTokenizer.tokenize(line)
        } else {
            command = []
        }

        // environment: ["K=V"] | {K: V}
        if let list = try? c.decode([ComposeScalar].self, forKey: .environment) {
            environment = list.map(\.value)
        } else if let map = try? c.decode([String: ComposeScalar].self, forKey: .environment) {
            environment = map.map { "\($0.key)=\($0.value.value)" }.sorted()
        } else {
            environment = []
        }

        // ports: [int|string] — normalized to "host:container[/proto]" strings.
        let rawPorts = (try? c.decode([ComposeScalar].self, forKey: .ports))?.map(\.value)
        ports = (rawPorts ?? []).map(Self.normalizePort)

        // volumes: ["source:target[:mode]"] (short syntax).
        volumes = (try? c.decode([ComposeScalar].self, forKey: .volumes))?.map(\.value) ?? []

        // networks: [name]
        networks = (try? c.decode([ComposeScalar].self, forKey: .networks))?.map(\.value) ?? []

        // depends_on: [name] | {name: {condition: …}} — only the names matter here.
        if let list = try? c.decode([String].self, forKey: .dependsOn) {
            dependsOn = list
        } else if let map = try? c.decode([String: DependsCondition].self, forKey: .dependsOn) {
            dependsOn = Array(map.keys)
        } else {
            dependsOn = []
        }

        // user: scalar (string or int, e.g. "0" / "1000:1000" / "mysql").
        user = (try? c.decode(ComposeScalar.self, forKey: .user))?.value

        // Collect known-unsupported fields that are actually present.
        var ignored: [String] = []
        for (key, label) in [
            (CodingKeys.build, "build"),
            (.healthcheck, "healthcheck"),
            (.restart, "restart"),
            (.deploy, "deploy"),
            (.profiles, "profiles"),
            (.secrets, "secrets"),
            (.configs, "configs"),
            (.envFile, "env_file"),
        ] where c.contains(key) {
            ignored.append(label)
        }
        self.ignored = ignored
        // `expose` is intentionally NOT reported: same-network containers already
        // reach every port, so honoring it is a no-op rather than a limitation.
    }

    /// Normalize a compose port entry to the engine's `host:container/proto` form.
    /// `"3000:3000"` → `"3000:3000/tcp"`, `"8080:80/udp"` kept, a bare `"80"` →
    /// `"80:80/tcp"` (publish to the same host port).
    private static func normalizePort(_ raw: String) -> String {
        let (mapping, proto) = splitProto(raw)
        let parts = mapping.split(separator: ":", maxSplits: 1).map(String.init)
        let host: String
        let container: String
        if parts.count == 2 {
            host = parts[0]
            container = parts[1]
        } else {
            host = mapping
            container = mapping
        }
        return "\(host):\(container)/\(proto)"
    }

    private static func splitProto(_ raw: String) -> (mapping: String, proto: String) {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (parts[0], parts[1]) }
        return (raw, "tcp")
    }
}

/// The value side of a `depends_on:` map entry (`{condition: service_started}`).
/// We don't act on the condition (no health checks underneath), but decode it so
/// the map form parses.
private struct DependsCondition: Decodable {}

// MARK: - Lowering to ContainerCreateSpec

struct ComposeParseResult {
    /// Service names in dependency order (a service appears after everything it
    /// depends on), so Up can start them sequentially.
    var orderedServices: [String]
    /// Create specs keyed by service name.
    var specs: [String: ContainerCreateSpec]
    /// Actual (project-prefixed) network names to create before starting services.
    var declaredNetworks: [String]
    /// Actual (project-prefixed) volume names to create before starting services.
    var declaredVolumes: [String]
    /// Human-readable "ignored field" warnings, deduplicated.
    var warnings: [String]
}

extension ComposeFile {
    /// The label keys used to tag a container with its compose project/service.
    static let projectLabel = "com.icontainu.compose.project"
    static let serviceLabel = "com.icontainu.compose.service"

    /// Lower the file into create specs.
    ///
    /// - Parameters:
    ///   - project: project namespace; prefixes named volumes/networks and tags
    ///     every container's labels.
    ///   - baseDirectory: directory of the compose file, used to resolve relative
    ///     bind paths. `nil` for pasted YAML — a relative bind then throws.
    func toSpecs(project: String, baseDirectory: URL?) throws -> ComposeParseResult {
        guard !services.isEmpty else { throw ComposeError.noServices }

        let ordered = try Self.topologicalOrder(services: services)

        var specs: [String: ContainerCreateSpec] = [:]
        var warnings = Set<String>()

        for name in ordered {
            let svc = services[name]!
            for field in svc.ignored {
                warnings.insert("Service \"\(name)\": \(field) is not supported and was ignored.")
            }

            var spec = ContainerCreateSpec(image: svc.image ?? "")
            spec.name = svc.containerName ?? name
            spec.command = svc.command
            spec.env = svc.environment
            spec.publishPorts = svc.ports
            spec.volumes = try svc.volumes.map {
                try Self.resolveVolume($0, project: project, service: name, baseDirectory: baseDirectory)
            }
            spec.networks = svc.networks.map { "\(project)_\($0)" }
            spec.user = svc.user
            spec.labels = [
                Self.projectLabel: project,
                Self.serviceLabel: name,
            ]
            specs[name] = spec
        }

        let declaredNetworks = (networks?.keys ?? [:].keys).map { "\(project)_\($0)" }.sorted()
        let declaredVolumes = (volumes?.keys ?? [:].keys).map { "\(project)_\($0)" }.sorted()

        return ComposeParseResult(
            orderedServices: ordered,
            specs: specs,
            declaredNetworks: declaredNetworks,
            declaredVolumes: declaredVolumes,
            warnings: warnings.sorted())
    }

    /// Resolve a `source:target[:mode]` short-syntax volume into the engine's CLI
    /// form. A source containing "/" is a bind mount (relative paths resolved
    /// against `baseDirectory`); otherwise it's a named volume and gets the project
    /// prefix.
    private static func resolveVolume(
        _ raw: String, project: String, service: String, baseDirectory: URL?
    ) throws -> String {
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return raw }
        let source = parts[0]
        let target = parts[1]
        let mode = parts.count >= 3 ? parts[2] : nil

        let resolvedSource: String
        if source.contains("/") || source.hasPrefix("~") {
            // Bind mount.
            if source.hasPrefix("/") {
                resolvedSource = source
            } else if source.hasPrefix("~") {
                resolvedSource = (source as NSString).expandingTildeInPath
            } else {
                guard let base = baseDirectory else {
                    throw ComposeError.relativeBindWithoutBaseDirectory(service: service, source: source)
                }
                resolvedSource = URL(fileURLWithPath: source, relativeTo: base).standardizedFileURL.path
            }
        } else {
            // Named volume — project-scoped.
            resolvedSource = "\(project)_\(source)"
        }

        if let mode {
            return "\(resolvedSource):\(target):\(mode)"
        }
        return "\(resolvedSource):\(target)"
    }

    /// Kahn's algorithm over the `depends_on` edges, with cycle detection. Returns
    /// service names such that each appears after every service it depends on.
    /// Ties are broken alphabetically for a deterministic order.
    private static func topologicalOrder(services: [String: ComposeService]) throws -> [String] {
        // Edges: dependency → dependent. Only count deps that name a real service.
        var indegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for name in services.keys { indegree[name] = 0 }

        for (name, svc) in services {
            for dep in svc.dependsOn where services[dep] != nil {
                dependents[dep, default: []].append(name)
                indegree[name, default: 0] += 1
            }
        }

        var ready = indegree.filter { $0.value == 0 }.map(\.key).sorted()
        var ordered: [String] = []
        while !ready.isEmpty {
            let next = ready.removeFirst()
            ordered.append(next)
            for dependent in (dependents[next] ?? []).sorted() {
                indegree[dependent]! -= 1
                if indegree[dependent]! == 0 {
                    // Insert keeping `ready` sorted for determinism.
                    let idx = ready.firstIndex { $0 > dependent } ?? ready.endIndex
                    ready.insert(dependent, at: idx)
                }
            }
        }

        guard ordered.count == services.count else {
            let cyclic = services.keys.filter { !ordered.contains($0) }.sorted()
            throw ComposeError.dependencyCycle(cyclic)
        }
        return ordered
    }
}

// MARK: - Parsing entry point

enum ComposeParser {
    /// Decode raw YAML text into a `ComposeFile`. Throws Yams decode errors with
    /// their original messages so a malformed file is explained to the user.
    static func parse(yaml: String) throws -> ComposeFile {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ComposeError.empty }
        return try YAMLDecoder().decode(ComposeFile.self, from: yaml)
    }
}
