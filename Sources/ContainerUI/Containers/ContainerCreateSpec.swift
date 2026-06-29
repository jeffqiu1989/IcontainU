import Foundation

/// User-provided inputs from the create-container form. Mirrors the subset of
/// `container run` flags the GUI exposes; everything else uses defaults.
///
/// The GUI always runs the container detached (`-d`) using the image's own
/// default command — it intentionally does not expose command/entrypoint editing
/// because there is no built-in terminal to interact with an overridden process.
struct ContainerCreateSpec {
    /// Image reference (e.g. "nginx:latest").
    var image: String
    /// Container name; nil auto-generates one.
    var name: String?
    /// Command tokens (argv). Empty keeps the image default. Per OCI semantics,
    /// when the image has an entrypoint these become its arguments; otherwise they
    /// are the command to execute.
    var command: [String] = []
    /// Port publishings in CLI form, e.g. "8080:80/tcp".
    var publishPorts: [String] = []
    /// Volume binds / mounts in CLI form, e.g. "/host:/data:ro" or "vol:/data".
    var volumes: [String] = []
    /// Environment variables in "KEY=VALUE" form.
    var env: [String] = []
    /// Networks to attach to. Empty uses the built-in default network; "none"
    /// disables networking; otherwise each entry is a named network.
    var networks: [String] = []
    /// Remove the container automatically when it stops (`--rm`).
    var autoRemove: Bool = false
    /// Forward the host SSH agent socket (`--ssh`).
    var ssh: Bool = false
    /// Labels applied to the container, keyed by name. Used by the Compose feature
    /// to tag containers with their project/service so a group can be listed and
    /// torn down together. Empty for a plain single-container create.
    var labels: [String: String] = [:]
    /// Run the container as this user — `name|uid[:gid]` form (compose `user:`).
    /// Nil uses the image's default user. Some images run as a non-root user that
    /// can't write their named-volume data dir (e.g. prometheus as `nobody`), so a
    /// compose file sets `user: "0"` to run as root and fix the permission.
    var user: String?
}
