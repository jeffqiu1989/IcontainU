import ContainerAPIClient
import ContainerResource
import Foundation
import TerminalProgress
import Testing

@testable import ContainerUI

/// End-to-end orchestration tests against the live `container` runtime, one per
/// awesome-compose example we committed to supporting. Gated on `ICONTAINU_E2E`
/// because they pull images, create real containers, and need the apiserver
/// running — too heavy and side-effecting for the normal suite.
///
/// Run with:  ICONTAINU_E2E=1 swift test --filter ComposeEngineE2ETests
///
/// Each test brings a project up through the real `ComposeEngine.up`, asserts the
/// services come up and resolve each other BY SERVICE NAME at their real eth0 IP
/// (proving the `/etc/hosts` injection works — the built-in DNS returns a broken
/// `28.0.0.x` address on macOS 26), then always tears the project down.
///
/// Serialized: the examples reuse service names like `db`, whose container names
/// are global, so they can't run concurrently.
@MainActor
@Suite(.serialized)
struct ComposeEngineE2ETests {
    private nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["ICONTAINU_E2E"] == "1"
    }

    private static let noopPhase: @Sendable (String) async -> ProgressUpdateHandler = { _ in
        { _ in }
    }

    // MARK: - The five awesome-compose examples

    @Test(.enabled(if: enabled, "set ICONTAINU_E2E=1 to run"))
    func giteaPostgres() async throws {
        try await withProject(example: "gitea-postgres", project: "e2e-gitea") { _ in
            try await Self.expectResolves(from: "gitea", to: "db")
        }
    }

    @Test(.enabled(if: enabled, "set ICONTAINU_E2E=1 to run"))
    func nextcloudPostgres() async throws {
        try await withProject(example: "nextcloud-postgres", project: "e2e-ncpg") { _ in
            try await Self.expectResolves(from: "nc", to: "db")
        }
    }

    @Test(.enabled(if: enabled, "set ICONTAINU_E2E=1 to run"))
    func nextcloudRedisMariadb() async throws {
        try await withProject(example: "nextcloud-redis-mariadb", project: "e2e-ncrm") { _ in
            // The hub service `nc` must reach BOTH peers, each on a different network.
            try await Self.expectResolves(from: "nc", to: "redis")
            try await Self.expectResolves(from: "nc", to: "db")
        }
    }

    @Test(.enabled(if: enabled, "set ICONTAINU_E2E=1 to run"))
    func prometheusGrafana() async throws {
        try await withProject(example: "prometheus-grafana", project: "e2e-promgraf") { _ in
            // Relative bind mount resolved against the file's dir: prometheus must
            // see its config file.
            let cfg = try Self.exec(container: "prometheus", "cat", "/etc/prometheus/prometheus.yml")
            #expect(cfg.contains("scrape_configs") || cfg.contains("global"),
                "prometheus.yml should be mounted from the relative bind path")
            // grafana resolves prometheus by name (its provisioned datasource).
            try await Self.expectResolves(from: "grafana", to: "prometheus")
        }
    }

    @Test(.enabled(if: enabled, "set ICONTAINU_E2E=1 to run"))
    func wordpressMysql() async throws {
        try await withProject(example: "wordpress-mysql", project: "e2e-wp") { _ in
            // Headline case: a stateful protocol (MySQL) must connect by service
            // name — exactly what the broken DNS breaks and the hosts injection fixes.
            var connected = false
            for _ in 0..<30 {
                let out = (try? Self.exec(
                    container: "wordpress", "php", "-r",
                    "$m=@mysqli_connect('db','wordpress','wordpress','wordpress');"
                        + "echo $m?'CONNECTED':'FAIL:'.mysqli_connect_error();"
                )) ?? ""
                if out.contains("CONNECTED") { connected = true; break }
                try await Task.sleep(for: .seconds(2))
            }
            #expect(connected, "wordpress must connect to mariadb by service name 'db'")
        }
    }

    /// Fast alpine-only multi-network sanity check (no heavy images): a hub on two
    /// networks resolves a peer on each.
    @Test(.enabled(if: enabled, "set ICONTAINU_E2E=1 to run"))
    func multiNetworkDiscovery() async throws {
        let yaml = """
            services:
              svchub:
                image: docker.io/library/alpine:latest
                command: sleep 600
                networks: [neta, netb]
              alpha:
                image: docker.io/library/alpine:latest
                command: sleep 600
                networks: [neta]
              beta:
                image: docker.io/library/alpine:latest
                command: sleep 600
                networks: [netb]
            networks:
              neta:
              netb:
            """
        let project = "e2e-multinet"
        let parse = try ComposeParser.parse(yaml: yaml).toSpecs(project: project, baseDirectory: nil)
        let record = ComposeProjectRecord(
            name: project, yaml: yaml, baseDirectoryPath: nil,
            declaredNetworks: parse.declaredNetworks, declaredVolumes: parse.declaredVolumes,
            importedAt: Date())
        do {
            try await ComposeEngine.up(project: project, parse: parse, beginPhase: Self.noopPhase)
            let nets = Set((try await NetworkClient().list()).map(\.id))
            #expect(nets.contains("e2e-multinet_neta"))
            #expect(nets.contains("e2e-multinet_netb"))
            try await Self.expectResolves(from: "svchub", to: "alpha")
            try await Self.expectResolves(from: "svchub", to: "beta")
        } catch {
            try? await ComposeEngine.down(project: project, record: record, removeVolumes: true, removeNetworks: true)
            throw error
        }
        try? await ComposeEngine.down(project: project, record: record, removeVolumes: true, removeNetworks: true)
    }

    // MARK: - Harness

    /// Up the named example from `~/awesome-compose`, run `body`, then always tear
    /// it down (containers + networks + volumes). Asserts every declared service is
    /// running before handing off to `body`.
    private func withProject(
        example: String, project: String,
        _ body: (ComposeParseResult) async throws -> Void
    ) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appending(path: "awesome-compose/\(example)/compose.yaml")
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let baseDir = url.deletingLastPathComponent()
        let parse = try ComposeParser.parse(yaml: yaml).toSpecs(project: project, baseDirectory: baseDir)
        let record = ComposeProjectRecord(
            name: project, yaml: yaml, baseDirectoryPath: baseDir.path,
            declaredNetworks: parse.declaredNetworks, declaredVolumes: parse.declaredVolumes,
            importedAt: Date())

        do {
            try await ComposeEngine.up(project: project, parse: parse, beginPhase: Self.noopPhase)

            // Every declared service exists, named by its bare service name, labeled.
            let client = ContainerClient()
            let mine = try await client.list(filters: ContainerListFilters.all.withoutMachines())
                .filter { $0.configuration.labels[ComposeFile.projectLabel] == project }
            #expect(Set(mine.map(\.id)) == Set(parse.orderedServices))

            try await body(parse)
        } catch {
            try? await ComposeEngine.down(project: project, record: record, removeVolumes: true, removeNetworks: true)
            throw error
        }
        try? await ComposeEngine.down(project: project, record: record, removeVolumes: true, removeNetworks: true)
    }

    /// Assert that `from` resolves `to` to a REAL `192.168.x` IP — proof the hosts
    /// injection worked. The broken built-in DNS would instead yield `28.0.0.x`.
    /// Polls because a just-started container needs a moment before exec works.
    private static func expectResolves(from container: String, to name: String) async throws {
        var ip = ""
        for _ in 0..<20 {
            let out = (try? exec(container: container, "getent", "hosts", name)) ?? ""
            // getent line: "<ip>   <name> ..."
            if let first = out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first {
                ip = String(first)
            }
            if ip.hasPrefix("192.168.") { break }
            try await Task.sleep(for: .seconds(2))
        }
        #expect(ip.hasPrefix("192.168."),
            "\(container) should resolve '\(name)' to a real 192.168.x IP (got '\(ip)')")
    }

    /// Run a command in a container via the `container` CLI and return its stdout.
    private static func exec(container: String, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
        process.arguments = ["exec", container] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
