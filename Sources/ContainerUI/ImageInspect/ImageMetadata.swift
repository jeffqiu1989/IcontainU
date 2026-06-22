import ContainerizationOCI
import Foundation

/// Configuration distilled from an image, used to pre-fill the create-container
/// form so the user doesn't have to consult documentation for ports, volumes and
/// environment variables.
struct ImageMetadata {
    /// Default command (OCI `Cmd`).
    var command: [String] = []
    /// Entrypoint (OCI `Entrypoint`).
    var entrypoint: [String] = []
    /// Working directory (OCI `WorkingDir`).
    var workingDir: String?
    /// Default user (OCI `User`).
    var user: String?
    /// Stop signal (OCI `StopSignal`).
    var stopSignal: String?
    /// Labels (OCI `Labels`).
    var labels: [String: String] = [:]

    /// Build-time env baked into the image (OCI `Env`) — mostly version metadata.
    var buildEnv: [EnvVar] = []
    /// Env vars the entrypoint script reads — the ones a user typically must set
    /// (e.g. MYSQL_ROOT_PASSWORD). Extracted heuristically from the entrypoint.
    var userEnv: [String] = []

    /// Ports the image declares via `EXPOSE` (from history), e.g. "80/tcp".
    var exposedPorts: [String] = []
    /// Volumes the image declares via `VOLUME` (from history), e.g. "/var/lib/mysql".
    var volumes: [String] = []

    struct EnvVar {
        var key: String
        var value: String
    }
}
