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
    /// A dependency declared with `condition: service_healthy` did not become
    /// healthy within its healthcheck window. Thrown from the Up loop so the
    /// caller surfaces it and points the user at the dependency's logs.
    case serviceUnhealthy(service: String, dependency: String)

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
        case .serviceUnhealthy(let service, let dependency):
            return
                "Service \"\(service)\" depends on \"\(dependency)\", which did not become "
                + "healthy within its health-check window."
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

// MARK: - Healthcheck

/// A compose `healthcheck:` block, lowered into a probe the engine runs via
/// `container exec` during Up. Only the fields the awesome-compose examples use
/// are honored: `test`, `interval`, `timeout`, `retries`, `start_period`.
/// `start_interval` and `disable` are parsed (so they don't trip the unknown-
/// field path) but otherwise ignored — neither appears in real samples.
struct ComposeHealthcheck: Decodable {
    /// What to run. `["CMD", ...]` execs the argv directly; `["CMD-SHELL", "<s>"]`
    /// (or a bare `test:` string) runs `<s>` through `/bin/sh -c`; `["NONE"]` or
    /// `disable: true` disables the check (the service starts with no gating).
    var probe: ProbeSpec
    var interval: TimeInterval
    var timeout: TimeInterval
    var retries: Int
    /// Grace period during which probe failures don't count toward `retries`.
    var startPeriod: TimeInterval

    enum ProbeSpec: Equatable {
        case cmd([String])
        case cmdShell(String)
        case none
    }

    private enum CodingKeys: String, CodingKey {
        case test, interval, timeout, retries
        case startPeriod = "start_period"
        case startInterval = "start_interval"
        case disable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let disabled = (try? c.decode(Bool.self, forKey: .disable)) ?? false

        if let s = try? c.decode(String.self, forKey: .test) {
            // Bare string form — docker treats it as CMD-SHELL.
            probe = disabled ? .none : .cmdShell(s)
        } else if let arr = try? c.decode([String].self, forKey: .test) {
            probe = disabled ? .none : Self.parseArray(arr)
        } else {
            // A healthcheck block without a `test` is a no-op for us (we don't
            // inherit image HEALTHCHECK), so treat it as disabled.
            probe = .none
        }

        interval = Self.parseDuration(try? c.decode(String.self, forKey: .interval), default: 30)
        timeout = Self.parseDuration(try? c.decode(String.self, forKey: .timeout), default: 30)
        retries = (try? c.decode(Int.self, forKey: .retries)) ?? 3
        startPeriod = Self.parseDuration(try? c.decode(String.self, forKey: .startPeriod), default: 0)
    }

    /// Interpret a `test:` array by its leading element, matching docker:
    /// `CMD` execs the rest as argv; `CMD-SHELL` joins the rest into one shell
    /// script; `NONE` disables; an array with no recognized prefix is treated
    /// as `CMD`.
    private static func parseArray(_ arr: [String]) -> ProbeSpec {
        guard let head = arr.first else { return .none }
        let rest = Array(arr.dropFirst())
        switch head {
        case "NONE":
            return .none
        case "CMD":
            return rest.isEmpty ? .none : .cmd(rest)
        case "CMD-SHELL":
            // The script is a single string; join defensively in case it was
            // split across array elements.
            return .cmdShell(rest.joined(separator: " "))
        default:
            return .cmd(arr)
        }
    }

    /// Parse a compose duration string ("30s", "3m", "2h") into seconds. The
    /// awesome-compose examples use only `s`; `m`/`h` are accepted for
    /// completeness. Whole or fractional numbers are supported; an unknown or
    /// missing value falls back to `defaultValue`.
    private static func parseDuration(_ raw: String?, default defaultValue: TimeInterval) -> TimeInterval {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return defaultValue
        }
        var unit: Character = "s"
        var numberString = raw
        if let last = raw.last, !last.isNumber && last != "." {
            unit = last
            numberString = String(raw.dropLast())
        }
        guard let value = Double(numberString) else { return defaultValue }
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        default: return defaultValue
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
    /// Per-dependency `condition` values from the map form of `depends_on`
    /// (`{db: {condition: service_healthy}}`). Empty for the list form. Keys
    /// without a condition default to `service_started` (no gating).
    var dependsOnConditions: [String: String]
    /// Run the container as this user — compose `user:` (a string like "0",
    /// "1000:1000", or "mysql"). YAML numbers are accepted.
    var user: String?
    /// A `healthcheck:` block, if declared. `nil` when absent; a probe of
    /// `.none` when present but disabled (`["NONE"]` / `disable: true`).
    var healthcheck: ComposeHealthcheck?
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
        case healthcheck
        // Known but unsupported — presence is reported, value ignored.
        case build
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

        // depends_on: [name] | {name: {condition: …}}. The list form gives plain
        // names (started semantics, no gating); the map form also yields a
        // `condition` per dependency — `service_healthy` makes the Up loop wait
        // for the dependency's healthcheck before starting this service.
        if let list = try? c.decode([String].self, forKey: .dependsOn) {
            dependsOn = list
            dependsOnConditions = [:]
        } else if let map = try? c.decode([String: DependsCondition].self, forKey: .dependsOn) {
            dependsOn = Array(map.keys)
            // Keep only the non-empty conditions (a `null` value or missing
            // `condition` means the default `service_started`).
            dependsOnConditions = map.compactMapValues { $0.condition }
                .filter { !$0.value.isEmpty }
        } else {
            dependsOn = []
            dependsOnConditions = [:]
        }

        // user: scalar (string or int, e.g. "0" / "1000:1000" / "mysql").
        user = (try? c.decode(ComposeScalar.self, forKey: .user))?.value

        // healthcheck: optional block; decoded into a probe spec.
        healthcheck = try? c.decodeIfPresent(ComposeHealthcheck.self, forKey: .healthcheck)

        // Collect known-unsupported fields that are actually present.
        var ignored: [String] = []
        for (key, label) in [
            (CodingKeys.build, "build"),
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
/// We honor `service_healthy` (gating the dependent's start on the dependency's
/// healthcheck) and otherwise treat the dependency as started-only. `null`
/// values (`db:` with no body) decode to a nil condition (started).
private struct DependsCondition: Decodable {
    var condition: String?

    private enum CodingKeys: String, CodingKey { case condition }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        condition = try c.decodeIfPresent(String.self, forKey: .condition)
    }
}

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
    /// Healthcheck specs, keyed by service name, for services that declare a
    /// non-disabled probe. The Up loop runs these to gate `service_healthy`
    /// dependents. Topological order means a dependency is always present here
    /// before any service that depends on it is processed.
    var healthchecks: [String: ComposeHealthcheck]
    /// For each service, the dependencies it declared with
    /// `condition: service_healthy` AND that themselves declare a healthcheck —
    /// the Up loop waits for each to become healthy before starting the service.
    /// A `service_healthy` dependency without a healthcheck is reported as a
    /// warning (and treated as started-only) rather than blocking forever.
    var healthyDeps: [String: [String]]
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
        var healthchecks: [String: ComposeHealthcheck] = [:]
        var healthyDeps: [String: [String]] = [:]

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

            // Record a real (non-disabled) healthcheck. Disabled probes (.none)
            // are intentionally not registered — no gating, no preview.
            if let hc = svc.healthcheck, hc.probe != .none {
                healthchecks[name] = hc
            }

            // `service_healthy` dependencies: only gate on ones that declare a
            // healthcheck. A `service_healthy` dep without one can never become
            // healthy, so rather than block forever we warn and treat it as
            // started-only. Topological order guarantees the dep was processed
            // (and registered in `healthchecks`) before this service.
            let healthyConditions = svc.dependsOnConditions
                .filter { $0.value == "service_healthy" }
            if !healthyConditions.isEmpty {
                var gated: [String] = []
                for dep in healthyConditions.keys.sorted() where services[dep] != nil {
                    if healthchecks[dep] != nil {
                        gated.append(dep)
                    } else {
                        warnings.insert(
                            "Service \"\(name)\": depends_on \"\(dep)\" with condition "
                            + "service_healthy, but \"\(dep)\" declares no healthcheck — "
                            + "starting after it is started instead.")
                    }
                }
                if !gated.isEmpty { healthyDeps[name] = gated }
            }
        }

        let declaredNetworks = (networks?.keys ?? [:].keys).map { "\(project)_\($0)" }.sorted()
        let declaredVolumes = (volumes?.keys ?? [:].keys).map { "\(project)_\($0)" }.sorted()

        return ComposeParseResult(
            orderedServices: ordered,
            specs: specs,
            declaredNetworks: declaredNetworks,
            declaredVolumes: declaredVolumes,
            warnings: warnings.sorted(),
            healthchecks: healthchecks,
            healthyDeps: healthyDeps)
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
