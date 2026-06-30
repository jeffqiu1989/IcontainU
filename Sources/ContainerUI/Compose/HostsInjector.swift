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
/// The block is rendered per-receiving-container, not once per project: a service
/// on several networks has several IPs, and we want each peer to see the IP on a
/// network it actually shares with the target (an IP on an unshared network isn't
/// routable from that peer). When a target has no shared network with the receiver
/// we fall back to its first IP (the prior behavior).
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

    /// One service's presence on the network: its real IPv4 address on each
    /// network it's attached to, plus the container id and (when different from the
    /// service name) the container_name to also publish as an alias.
    struct ServiceEndpoint {
        /// service name (the primary DNS name).
        var service: String
        /// container id (== container_name when one was pinned).
        var containerID: String
        /// network id → IPv4 address, for every network the container is on.
        var ipsByNetwork: [String: String]
        /// First IP (deterministic fallback when no network is shared).
        var fallbackIP: String
    }

    /// One project's resolved topology: every service's endpoint, plus, for each
    /// receiving container, the set of networks it's attached to (so injection can
    /// pick a shared-network IP for each peer).
    struct ProjectMapping {
        /// service name → endpoint.
        var endpoints: [String: ServiceEndpoint]
        /// container id → the networks that container is attached to.
        var containerNetworks: [String: Set<String>]
    }

    /// Build per-project topology from a container snapshot list. A container
    /// contributes its service label (or, as a fallback for projects started
    /// outside the app, its id) and the IPv4 address on each network it's attached
    /// to.
    static func mappings(containers: [ContainerSnapshot]) -> [String: ProjectMapping] {
        var projects: [String: ProjectMapping] = [:]
        for snapshot in containers {
            guard let project = snapshot.configuration.labels[ComposeFile.projectLabel] else { continue }
            // Collect IPv4 per network; skip a container with no usable address.
            var ipsByNetwork: [String: String] = [:]
            for attachment in snapshot.networks {
                let ip = attachment.ipv4Address.address.description
                guard !ip.isEmpty else { continue }
                ipsByNetwork[attachment.network] = ip
            }
            guard let fallbackIP = snapshot.networks.first?.ipv4Address.address.description,
                !fallbackIP.isEmpty
            else { continue }

            let service = snapshot.configuration.labels[ComposeFile.serviceLabel] ?? snapshot.id
            var mapping = projects[project] ?? ProjectMapping(endpoints: [:], containerNetworks: [:])
            mapping.endpoints[service] = ServiceEndpoint(
                service: service,
                containerID: snapshot.id,
                ipsByNetwork: ipsByNetwork,
                fallbackIP: fallbackIP)
            mapping.containerNetworks[snapshot.id] = Set(ipsByNetwork.keys)
            projects[project] = mapping
        }
        return projects
    }

    /// Inject (or refresh) the hosts block in every container of the given
    /// mappings. Safe to call repeatedly: each container's block is replaced, not
    /// appended, so a changed IP fully overwrites the stale one. Failures for a
    /// single container (e.g. stopped mid-write, or no `/bin/sh` in the image) are
    /// logged and skipped — this is best-effort wiring, not a critical-path
    /// operation. Returns the set of `(project)` names that had at least one
    /// container we couldn't write to, so the UI can flag degraded discovery.
    @discardableResult
    static func inject(_ mappings: [String: ProjectMapping]) async -> Set<String> {
        var degraded: Set<String> = []
        for (project, mapping) in mappings {
            guard !mapping.endpoints.isEmpty else { continue }
            for (id, networks) in mapping.containerNetworks {
                let block = hostsBlock(for: mapping, receiverID: id, receiverNetworks: networks)
                do {
                    try await rewrite(container: id, block: block)
                } catch {
                    degraded.insert(project)
                    log.debug("hosts inject skipped", metadata: [
                        "id": "\(id)", "project": "\(project)", "error": "\(error.localizedDescription)",
                    ])
                }
            }
            log.info("injected service hosts", metadata: [
                "project": "\(project)",
                "services": "\(mapping.endpoints.keys.sorted())",
            ])
        }
        return degraded
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

    /// Render the hosts block for one receiving container: sentinel begin, one
    /// `<ip> <name>` line per OTHER service (sorted for determinism), sentinel end.
    /// For each target service the IP is chosen on a network the receiver shares
    /// with it (falling back to the target's first IP). When a target pinned a
    /// `container_name` different from its service name, an extra alias line maps
    /// that name too — matching docker, where both resolve.
    private static func hostsBlock(
        for mapping: ProjectMapping, receiverID: String, receiverNetworks: Set<String>
    ) -> String {
        var lines = [begin]
        for service in mapping.endpoints.keys.sorted() {
            guard let endpoint = mapping.endpoints[service] else { continue }
            // Prefer an IP on a network the receiver is also attached to; otherwise
            // fall back to the target's first IP (prior behavior).
            let shared = receiverNetworks.first { endpoint.ipsByNetwork[$0] != nil }
            let ip = shared.flatMap { endpoint.ipsByNetwork[$0] } ?? endpoint.fallbackIP
            lines.append("\(ip) \(service)")
            // container_name alias (only when it differs from the service name).
            if endpoint.containerID != service {
                lines.append("\(ip) \(endpoint.containerID)")
            }
        }
        lines.append(end)
        return lines.joined(separator: "\n")
    }
}
