import Foundation

/// Lightweight per-service override stored alongside the original YAML. Only
/// fields the user actually changed are populated; `nil` means "use YAML default."
/// Backward-compatible: old records without this field decode as `nil`.
struct ServiceOverride: Codable, Equatable {
    var containerName: String?
    var image: String?
    var command: [String]?
    var publishPorts: [String]?
    var env: [String]?
    var volumes: [String]?
    var networks: [String]?
    var user: String?
}

/// Overall form state for the compose import sheet. Holds the parsed service
/// configs (editable), project metadata, and drives the Up flow.
@Observable
@MainActor
final class ComposeImportFormState {
    var projectName: String = ""
    var yamlText: String = ""
    var baseDirectory: URL?

    /// Editable service configs in topological order.
    var serviceConfigs: [ComposeServiceConfig] = []

    /// Project-prefixed resource names (from the parsed result).
    var declaredNetworks: [String] = []
    var declaredVolumes: [String] = []

    /// Ignored-field warnings from parsing.
    var warnings: [String] = []

    /// Parse error message (shown in the error box).
    var analyzeError: String?

    /// Retained parse result — carries healthchecks and healthyDeps which are
    /// read-only metadata not represented in ComposeServiceConfig.
    private(set) var parseResult: ComposeParseResult?

    // MARK: - Container name derivation

    /// Auto-derive the default container name for a service.
    func defaultContainerName(for serviceName: String) -> String {
        let project = projectName.trimmingCharacters(in: .whitespaces)
        return "\(project)-\(serviceName)"
    }

    // MARK: - Parse result from edited configs

    /// Build a `ComposeParseResult` from the current edited form state, for the
    /// engine to consume during Up. Applies project prefixes to volumes/networks
    /// and assembles healthcheck/healthyDeps metadata from the original parse.
    func makeParseResult(baseDirectory: URL?) throws -> ComposeParseResult {
        guard !serviceConfigs.isEmpty else { throw ComposeError.noServices }

        // Topological sort using current dependsOn references.
        let ordered = try topologicalOrder()

        var specs: [String: ContainerCreateSpec] = [:]
        for config in serviceConfigs {
            let spec = try config.makeSpec(
                project: projectName,
                serviceLabel: config.serviceName,
                baseDirectory: baseDirectory
            )
            specs[config.serviceName] = spec
        }

        // Carry over healthchecks and healthyDeps from the original parse.
        // These are read-only — the form doesn't edit healthcheck definitions.
        let healthchecks = parseResult?.healthchecks ?? [:]
        let healthyDeps = parseResult?.healthyDeps ?? [:]

        return ComposeParseResult(
            orderedServices: ordered,
            specs: specs,
            declaredNetworks: declaredNetworks,
            declaredVolumes: declaredVolumes,
            warnings: warnings,
            healthchecks: healthchecks,
            healthyDeps: healthyDeps
        )
    }

    /// Build a minimal set of per-service overrides by diffing the current form
    /// state against the original parsed `ComposeFile`. Only changed fields are
    /// included.
    func buildServiceOverrides(from file: ComposeFile) -> [String: ServiceOverride] {
        var overrides: [String: ServiceOverride] = [:]
        for config in serviceConfigs {
            guard let original = file.services[config.serviceName] else { continue }
            if let override = config.buildOverride(original: original, project: projectName) {
                overrides[config.serviceName] = override
            }
        }
        return overrides.isEmpty ? [:] : overrides
    }

    // MARK: - Populate from parsed file

    /// Populate the form state from a parsed `ComposeFile` and its `ComposeParseResult`.
    func load(from file: ComposeFile, parseResult: ComposeParseResult) {
        self.parseResult = parseResult
        self.declaredNetworks = parseResult.declaredNetworks
        self.declaredVolumes = parseResult.declaredVolumes
        self.warnings = parseResult.warnings

        self.serviceConfigs = parseResult.orderedServices.compactMap { name in
            guard let service = file.services[name] else { return nil }
            return ComposeServiceConfig.from(
                name: name,
                service: service,
                defaultContainerName: defaultContainerName(for: name)
            )
        }
    }

    // MARK: - Topological sort (Kahn's algorithm)

    private func topologicalOrder() throws -> [String] {
        let names = serviceConfigs.map(\.serviceName)
        var indegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for name in names { indegree[name] = 0 }

        for config in serviceConfigs {
            for dep in config.dependsOn where names.contains(dep) {
                dependents[dep, default: []].append(config.serviceName)
                indegree[config.serviceName, default: 0] += 1
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
                    let idx = ready.firstIndex { $0 > dependent } ?? ready.endIndex
                    ready.insert(dependent, at: idx)
                }
            }
        }

        guard ordered.count == names.count else {
            let cyclic = names.filter { !ordered.contains($0) }.sorted()
            throw ComposeError.dependencyCycle(cyclic)
        }
        return ordered
    }
}
