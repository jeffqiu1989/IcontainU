import ContainerizationOCI
import Foundation

/// User-provided inputs from the build-image form. Mirrors the subset of
/// `container build` flags the GUI exposes; everything else uses defaults.
///
/// The engine assembles a `Builder.BuildConfig` from these and always exports a
/// single OCI image into the local image store (the `type=oci` default) — tar and
/// local outputs are intentionally not exposed in this phase.
struct BuildSpec {
    /// Build context directory. Sent to BuildKit as a path; the builder pulls the
    /// context files it needs on demand, so the directory is not pre-tarred here.
    var contextDir: URL
    /// Path to the Dockerfile/Containerfile driving the build. Defaults to
    /// `contextDir/Dockerfile`; the form auto-detects and lets the user re-pick.
    var dockerfilePath: URL
    /// Image names to tag the result with (e.g. "myapp:latest"). At least one
    /// non-empty tag is required — the form enforces this so a build never lands
    /// under an unreadable UUID name (the CLI's default).
    var tags: [String] = []
    /// Target platforms (e.g. linux/arm64, linux/amd64). Empty builds for the
    /// host platform. amd64 on Apple silicon builds through Rosetta by default.
    var platforms: [Platform] = []
    /// Skip the build cache (`--no-cache`).
    var noCache: Bool = false
    /// Build-time variables in "KEY=VALUE" form (`--build-arg`).
    var buildArgs: [String] = []
    /// Target build stage for a multi-stage Dockerfile (`--target`). Empty builds
    /// the final stage.
    var target: String = ""
    /// Labels applied to the built image, in "KEY=VALUE" form (`--label`).
    var labels: [String] = []
    /// Build secrets keyed by id (`--secret id=<key>,...`). The value is resolved
    /// at build time from a file or an environment variable; secret values are
    /// never surfaced back to the UI.
    var secrets: [String: SecretSource] = [:]
    /// Always attempt to pull a newer version of the base image (`--pull`).
    var pull: Bool = false
}

/// Where a build secret's value comes from. Mirrors the CLI's
/// `--secret id=<key>[,env=<VAR>|,src=<path>]` shapes.
enum SecretSource: Sendable {
    /// Read the secret value from a file on the host.
    case file(URL)
    /// Read the secret value from a host environment variable.
    case env(String)
}
