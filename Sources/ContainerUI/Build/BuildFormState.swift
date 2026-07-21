import ContainerizationOCI
import Foundation

/// Editable row model for the build form's tag editor. Mirrors the `PortRow`/
/// `EnvRow` convention: a stable `id`, a plain string field, and a `cliValue`
/// that returns nil for an empty row so blanks are dropped.

/// One image tag row (e.g. "myapp:latest"). At least one non-empty tag is
/// required to build - see `BuildFormState.isValid`.
struct TagRow: Identifiable {
    let id = UUID()
    var value: String = ""

    var trimmed: String { value.trimmingCharacters(in: .whitespaces) }
    var cliValue: String? { trimmed.isEmpty ? nil : trimmed }
}

/// Form state holder for the build sheet. Mirrors `CreateContainerFormState`:
/// the tag editor always keeps at least one (possibly empty) row so the inline
/// editor shows a fillable line; empty rows are dropped at `makeSpec` time.
@Observable
@MainActor
final class BuildFormState {
    /// Dockerfile path - the form's primary picker. The build context is derived
    /// from its directory (see `contextPath`), matching `docker build`'s default.
    var dockerfilePath: String = ""

    /// Build context directory, derived read-only from the Dockerfile's parent.
    /// Standalone builds always use the Dockerfile's folder as context; compose
    /// builds set their own context elsewhere and never touch this form.
    var contextPath: String {
        let path = dockerfilePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path(percentEncoded: false)
    }

    var tags: [TagRow] = [TagRow()]
    /// Target architectures - two independent toggles. (The old 3-way segmented
    /// picker encoded this as an enum, but arm64/amd64 really are orthogonal.)
    /// amd64 on Apple Silicon builds through Rosetta. At least one must stay on.
    var arm64 = true
    var amd64 = false
    /// No cache defaults ON: a no-cache build also deletes the builder afterward
    /// (no disk growth), which is the safer default for this app.
    var noCache = true
    var pull = false

    /// The OCI platforms to build for, derived from the toggles (linux only).
    var platforms: [Platform] {
        var p: [Platform] = []
        if arm64 { p.append(try! Platform(from: "linux/arm64")) }
        if amd64 { p.append(try! Platform(from: "linux/amd64")) }
        return p
    }

    /// A build needs a readable Dockerfile path, ≥1 non-empty tag, and ≥1 platform.
    /// The context is implied by the Dockerfile, so it needn't be validated.
    var isValid: Bool {
        !dockerfilePath.trimmingCharacters(in: .whitespaces).isEmpty
            && tags.contains { $0.cliValue != nil }
            && (arm64 || amd64)
    }

    /// Pre-fill from a persisted record (edit mode). Context is derived from the
    /// Dockerfile, so it isn't restored - a re-pick isn't needed.
    func apply(record: BuildConfigRecord) {
        dockerfilePath = record.dockerfilePath
        tags = record.tags.isEmpty ? [TagRow()] : record.tags.map { TagRow(value: $0) }
        // Empty (old/default) records build for the host arch (arm64) only.
        let hasARM = record.platforms.contains { $0.contains("arm64") }
        let hasAMD = record.platforms.contains { $0.contains("amd64") }
        arm64 = record.platforms.isEmpty || hasARM
        amd64 = hasAMD
        noCache = record.noCache
        pull = record.pull
    }

    /// Assemble the immutable `BuildSpec` from the current form values.
    /// buildArgs/target/labels stay empty - the form no longer exposes them (ARG
    /// defaults usually suffice; edit the Dockerfile or use compose for more).
    func makeSpec() -> BuildSpec {
        let dockerfileURL = URL(fileURLWithPath: dockerfilePath)
        return BuildSpec(
            contextDir: dockerfileURL.deletingLastPathComponent(),
            dockerfilePath: dockerfileURL,
            tags: tags.compactMap { $0.cliValue },
            platforms: platforms,
            noCache: noCache,
            pull: pull)
    }
}
