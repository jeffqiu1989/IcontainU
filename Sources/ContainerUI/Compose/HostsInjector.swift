import ContainerResource
import Foundation
import Logging

/// Injects `<service-name> → <container-real-IP>` entries into each project
/// container's `/etc/hosts`, bypassing the broken built-in DNS.
///
/// On macOS 26 the runtime's container-to-container DNS resolves a service name
/// to a reserved `28.0.0.x` address that does NOT match the container's real
/// `eth0` IP (`192.168.64.x`). TCP handshakes pass but stateful protocols (MySQL,
/// PostgreSQL, …) fail mid-handshake ("server has gone away"). Writing the real IP
/// into `/etc/hosts` — which glibc/musl consult before DNS — makes `db:5432` work.
///
/// Entries are written between sentinel markers so a re-injection (after a
/// container restart changes its IP) can replace the whole block idempotently.
///
/// See memory `container-dns-reserved-28x-bug` for the full diagnosis.
enum HostsInjector {
    private static let log = Logger(label: "icontainu.compose.hosts")

    /// Sentinel lines bracketing the injected block, so we can replace just it.
    private static let begin = "# --- icontainu compose hosts begin ---"
    private static let end = "# --- icontainu compose hosts end ---"

    /// One project's resolved name→IP mapping, plus which containers belong to it.
    struct ProjectMapping {
        /// service name → real IPv4 address, for every running service.
        var hosts: [String: String]
        /// container ids that should receive the block.
        var containerIds: [String]
    }

    /// Build name→IP mappings for every project present in a container snapshot
    /// list. A container contributes its service label (or, as a fallback for
    /// projects started outside the app, its id) mapped to its first network's
    /// IPv4 address.
    static func mappings(containers: [ContainerSnapshot]) -> [String: ProjectMapping] {
        var projects: [String: ProjectMapping] = [:]
        for snapshot in containers {
            guard let project = snapshot.configuration.labels[ComposeFile.projectLabel] else { continue }
            guard let ip = snapshot.networks.first?.ipv4Address.address.description,
                !ip.isEmpty
            else { continue }
            let service = snapshot.configuration.labels[ComposeFile.serviceLabel] ?? snapshot.id
            var entry = projects[project] ?? ProjectMapping(hosts: [:], containerIds: [])
            // Prefer the first network's IP. If a service has multiple networks we
            // only need one reachable address per name for inter-service lookup.
            entry.hosts[service] = ip
            if !entry.containerIds.contains(snapshot.id) {
                entry.containerIds.append(snapshot.id)
            }
            projects[project] = entry
        }
        return projects
    }

    /// Inject (or refresh) the hosts block in every container of the given
    /// mappings. Safe to call repeatedly: each container's block is replaced, not
    /// appended, so a changed IP fully overwrites the stale one. Failures for a
    /// single container (e.g. stopped mid-write) are logged and skipped — this is
    /// best-effort wiring, not a critical-path operation.
    static func inject(_ mappings: [String: ProjectMapping]) async {
        for (project, mapping) in mappings {
            guard !mapping.hosts.isEmpty else { continue }
            let block = hostsBlock(for: mapping.hosts)
            for id in mapping.containerIds {
                do {
                    try await rewrite(container: id, block: block)
                } catch {
                    log.debug("hosts inject skipped", metadata: [
                        "id": "\(id)", "project": "\(project)", "error": "\(error.localizedDescription)",
                    ])
                }
            }
            log.info("injected service hosts", metadata: [
                "project": "\(project)",
                "services": "\(mapping.hosts.keys.sorted())",
            ])
        }
    }

    /// Rewrite `/etc/hosts` in `container`: strip any existing icontainu block,
    /// then append the fresh one. Uses `container exec sh -c` so the file edit runs
    /// inside the container filesystem (where `/etc/hosts` lives).
    static func rewrite(container id: String, block: String) async throws {
        // Read current /etc/hosts, drop any prior block (begin..end inclusive),
        // trim trailing newlines, append the new block. Done in one sh invocation
        // so there's no race between read and write.
        let script = """
            h=$(cat /etc/hosts 2>/dev/null || true)
            h=$(printf '%s\\n' "$h" | sed '/^# --- icontainu compose hosts begin ---$/,/^# --- icontainu compose hosts end ---$/d')
            printf '%s\\n%s\\n' "$h" '\(block)' > /etc/hosts
            """
        // Run as root (-u 0): many images (grafana, …) run as a non-root user that
        // can't write /etc/hosts, which would otherwise silently drop the entry.
        try await ContainerExec.run(id: id, command: "/bin/sh", args: ["-c", script], user: "0")
    }

    /// Render the hosts block: sentinel begin, one `<ip> <name>` line per service
    /// (sorted for determinism), sentinel end.
    private static func hostsBlock(for hosts: [String: String]) -> String {
        var lines = [begin]
        for name in hosts.keys.sorted() {
            lines.append("\(hosts[name]!) \(name)")
        }
        lines.append(end)
        return lines.joined(separator: "\n")
    }
}
