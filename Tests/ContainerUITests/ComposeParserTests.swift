import Foundation
import Testing

@testable import ContainerUI

/// Parser tests driven by the five real awesome-compose examples we committed to
/// supporting. Each asserts the field mappings that example specifically exercises
/// (numeric ports, array command, multi-network, relative binds, expose, …).
struct ComposeParserTests {

    // MARK: Polymorphic decoding

    @Test func environmentListForm() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    environment:
                      - FOO=bar
                      - NUM=5
                """)
        #expect(file.services["a"]?.environment.contains("FOO=bar") == true)
        // Unquoted numeric value decodes to its string form.
        #expect(file.services["a"]?.environment.contains("NUM=5") == true)
    }

    @Test func environmentMapForm() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    environment:
                      ROLE: backend
                      DEBUG: true
                """)
        let env = file.services["a"]?.environment ?? []
        #expect(env.contains("ROLE=backend"))
        #expect(env.contains("DEBUG=true"))
    }

    @Test func numericPortNormalized() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    ports:
                      - 3000:3000
                      - 80
                """)
        let ports = file.services["a"]?.ports ?? []
        #expect(ports.contains("3000:3000/tcp"))
        #expect(ports.contains("80:80/tcp"))
    }

    @Test func arrayCommand() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: prom/prometheus
                    command:
                      - '--config.file=/etc/prometheus/prometheus.yml'
                """)
        #expect(file.services["a"]?.command == ["--config.file=/etc/prometheus/prometheus.yml"])
    }

    @Test func stringCommandTokenized() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: mariadb
                    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
                """)
        #expect(
            file.services["a"]?.command == [
                "--transaction-isolation=READ-COMMITTED", "--binlog-format=ROW",
            ])
    }

    @Test func exposeIsAcceptedAndNotWarned() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: postgres
                    expose:
                      - 5432
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.warnings.isEmpty)
    }

    @Test func restartIsWarned() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    restart: always
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.warnings.contains { $0.contains("restart") })
    }

    // MARK: Long-syntax (unsupported) is warned, not silently dropped

    @Test func longSyntaxPortsWarnedAndDropped() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    ports:
                      - target: 80
                        published: 8080
                        protocol: tcp
                """)
        #expect(file.services["a"]?.ports.isEmpty == true)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.warnings.contains { $0.contains("ports") })
    }

    @Test func longSyntaxVolumesWarnedAndDropped() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    volumes:
                      - type: bind
                        source: ./data
                        target: /data
                """)
        #expect(file.services["a"]?.volumes.isEmpty == true)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.warnings.contains { $0.contains("volumes") })
    }

    @Test func shortSyntaxPortsNotWarned() throws {
        // A normal short-syntax ports list must NOT trip the long-syntax warning.
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    ports:
                      - 8080:80
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.warnings.contains { $0.contains("ports") } == false)
    }

    // MARK: Undeclared networks are auto-created + warned

    @Test func undeclaredNetworkIsAutoCreatedAndWarned() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    networks: [backend]
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        // The referenced-but-undeclared network is created so the service can attach.
        #expect(result.declaredNetworks == ["p_backend"])
        #expect(result.specs["a"]?.networks == ["p_backend"])
        #expect(result.warnings.contains { $0.contains("backend") })
    }

    @Test func declaredNetworkNotWarned() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    networks: [backend]
                networks:
                  backend:
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.declaredNetworks == ["p_backend"])
        #expect(result.warnings.contains { $0.contains("isn't declared") } == false)
    }

    @Test func userFieldParsedAndPassed() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    user: "0"
                  b:
                    image: alpine
                    user: 1000:1000
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.specs["a"]?.user == "0")
        // Numeric uid:gid form decodes to its string form.
        #expect(result.specs["b"]?.user == "1000:1000")
    }

    @Test func userAbsentIsNil() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.specs["a"]?.user == nil)
    }

    // MARK: Lowering

    @Test func dependsOnOrdersServices() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  web:
                    image: nginx
                    depends_on: [api]
                  api:
                    image: alpine
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        let apiIdx = result.orderedServices.firstIndex(of: "api")!
        let webIdx = result.orderedServices.firstIndex(of: "web")!
        #expect(apiIdx < webIdx)
    }

    @Test func dependencyCycleThrows() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    depends_on: [b]
                  b:
                    image: alpine
                    depends_on: [a]
                """)
        #expect(throws: ComposeError.self) {
            _ = try file.toSpecs(project: "p", baseDirectory: nil)
        }
    }

    @Test func serviceNameGetsProjectPrefix() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                """)
        let result = try file.toSpecs(project: "myproj", baseDirectory: nil)
        // Container name = <project>-<service> to avoid cross-project collisions.
        // /etc/hosts injection keys on the service label, not container name.
        #expect(result.specs["db"]?.name == "myproj-db")
    }

    @Test func containerNameOverridesProjectPrefix() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  svc:
                    image: prom/prometheus
                    container_name: prometheus
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.specs["svc"]?.name == "prometheus")
    }

    @Test func twoProjectsWithSameServiceNameGetDifferentContainerNames() throws {
        let yaml = """
            services:
              db:
                image: postgres
              web:
                image: nginx
                depends_on: [db]
            """
        let file = try ComposeParser.parse(yaml: yaml)
        let result1 = try file.toSpecs(project: "app1", baseDirectory: nil)
        let result2 = try file.toSpecs(project: "app2", baseDirectory: nil)
        #expect(result1.specs["db"]?.name == "app1-db")
        #expect(result2.specs["db"]?.name == "app2-db")
        #expect(result1.specs["web"]?.name == "app1-web")
        #expect(result2.specs["web"]?.name == "app2-web")
    }

    @Test func applyOverridesMergesServiceOverrides() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                    ports:
                      - "5432:5432"
                  web:
                    image: nginx
                    depends_on: [db]
                """)
        let overrides: [String: ServiceOverride] = [
            "db": ServiceOverride(image: "postgres:15", publishPorts: ["5433:5432"]),
            "web": ServiceOverride(containerName: "custom-web"),
        ]
        let overridden = file.applyOverrides(overrides)
        #expect(overridden.services["db"]?.image == "postgres:15")
        #expect(overridden.services["db"]?.ports == ["5433:5432"])
        #expect(overridden.services["web"]?.containerName == "custom-web")
        #expect(overridden.services["web"]?.image == "nginx")
    }

    @Test func namedVolumeGetsProjectPrefix() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                    volumes:
                      - db_data:/var/lib/postgresql/data
                volumes:
                  db_data:
                """)
        let result = try file.toSpecs(project: "myproj", baseDirectory: nil)
        #expect(result.specs["db"]?.volumes == ["myproj_db_data:/var/lib/postgresql/data"])
        #expect(result.declaredVolumes == ["myproj_db_data"])
    }

    @Test func networksGetProjectPrefix() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  nc:
                    image: nextcloud
                    networks: [redisnet, dbnet]
                networks:
                  redisnet:
                  dbnet:
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.specs["nc"]?.networks == ["p_redisnet", "p_dbnet"])
        #expect(Set(result.declaredNetworks) == ["p_redisnet", "p_dbnet"])
    }

    @Test func absoluteBindKept() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  a:
                    image: alpine
                    volumes:
                      - /host/path:/data:ro
                """)
        let result = try file.toSpecs(project: "p", baseDirectory: nil)
        #expect(result.specs["a"]?.volumes == ["/host/path:/data:ro"])
    }

    @Test func relativeBindResolvedAgainstBaseDirectory() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  prometheus:
                    image: prom/prometheus
                    volumes:
                      - ./prometheus:/etc/prometheus
                """)
        let base = URL(fileURLWithPath: "/Users/me/proj", isDirectory: true)
        let result = try file.toSpecs(project: "p", baseDirectory: base)
        #expect(result.specs["prometheus"]?.volumes == ["/Users/me/proj/prometheus:/etc/prometheus"])
    }

    @Test func relativeBindWithoutBaseDirectoryThrows() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  prometheus:
                    image: prom/prometheus
                    volumes:
                      - ./prometheus:/etc/prometheus
                """)
        #expect(throws: ComposeError.self) {
            _ = try file.toSpecs(project: "p", baseDirectory: nil)
        }
    }

    @Test func labelsTagProjectAndService() throws {
        let file = try ComposeParser.parse(
            yaml: """
                services:
                  web:
                    image: nginx
                """)
        let result = try file.toSpecs(project: "myproj", baseDirectory: nil)
        let labels = result.specs["web"]?.labels ?? [:]
        #expect(labels[ComposeFile.projectLabel] == "myproj")
        #expect(labels[ComposeFile.serviceLabel] == "web")
    }

    // MARK: Whole-file smoke tests against the committed examples

    /// Parses each real awesome-compose file (if present) end-to-end through
    /// `toSpecs`, asserting it doesn't throw and yields one spec per service.
    @Test(arguments: [
        ("gitea-postgres", ["gitea", "db"]),
        ("nextcloud-postgres", ["nc", "db"]),
        ("nextcloud-redis-mariadb", ["nc", "redis", "db"]),
        ("prometheus-grafana", ["prometheus", "grafana"]),
        ("wordpress-mysql", ["db", "wordpress"]),
    ])
    func realExampleParses(dir: String, expectedServices: [String]) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appending(path: "awesome-compose/\(dir)/compose.yaml")
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else {
            // Example not present on this machine — skip rather than fail.
            return
        }
        let file = try ComposeParser.parse(yaml: yaml)
        let result = try file.toSpecs(project: dir, baseDirectory: url.deletingLastPathComponent())
        #expect(Set(result.orderedServices) == Set(expectedServices))
        for svc in expectedServices {
            #expect(result.specs[svc]?.image.isEmpty == false)
        }
    }

    // MARK: healthcheck parsing

    @Test func healthcheckCmdArray() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                    healthcheck:
                      test: ["CMD", "pg_isready"]
                      interval: 10s
                      timeout: 5s
                      retries: 5
                """).toSpecs(project: "p", baseDirectory: nil)
        let hc = try #require(result.healthchecks["db"])
        // The CMD prefix is a docker marker, not part of the argv to run —
        // `["CMD","pg_isready"]` executes `pg_isready`, not `CMD pg_isready`.
        #expect(hc.probe == .cmd(["pg_isready"]))
        #expect(hc.interval == 10)
        #expect(hc.timeout == 5)
        #expect(hc.retries == 5)
        #expect(hc.startPeriod == 0)
    }

    @Test func healthcheckCmdShellArray() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: mysql
                    healthcheck:
                      test: ["CMD-SHELL", "mysqladmin ping --silent || exit 1"]
                      interval: 3s
                      retries: 5
                      start_period: 30s
                """).toSpecs(project: "p", baseDirectory: nil)
        let hc = try #require(result.healthchecks["db"])
        #expect(hc.probe == .cmdShell("mysqladmin ping --silent || exit 1"))
        #expect(hc.interval == 3)
        #expect(hc.retries == 5)
        #expect(hc.startPeriod == 30)
    }

    @Test func healthcheckStringFormIsCmdShell() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: redis
                    healthcheck:
                      test: redis-cli ping
                """).toSpecs(project: "p", baseDirectory: nil)
        #expect(result.healthchecks["db"]?.probe == .cmdShell("redis-cli ping"))
    }

    @Test func healthcheckNoneIsNotRegistered() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                    healthcheck:
                      test: ["NONE"]
                """).toSpecs(project: "p", baseDirectory: nil)
        #expect(result.healthchecks["db"] == nil)
    }

    @Test func healthcheckDefaultsApplied() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                    healthcheck:
                      test: ["CMD", "pg_isready"]
                """).toSpecs(project: "p", baseDirectory: nil)
        let hc = try #require(result.healthchecks["db"])
        #expect(hc.interval == 30)   // docker default
        #expect(hc.timeout == 30)
        #expect(hc.retries == 3)
        #expect(hc.startPeriod == 0)
    }

    @Test func healthcheckNotReportedAsIgnored() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                    healthcheck:
                      test: ["CMD", "pg_isready"]
                """).toSpecs(project: "p", baseDirectory: nil)
        #expect(result.warnings.contains { $0.contains("healthcheck") } == false)
    }

    @Test func serviceHealthyDependencyGates() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                    healthcheck:
                      test: ["CMD", "pg_isready"]
                  app:
                    image: nginx
                    depends_on:
                      db:
                        condition: service_healthy
                """).toSpecs(project: "p", baseDirectory: nil)
        #expect(result.healthyDeps["app"] == ["db"])
        #expect(result.orderedServices == ["db", "app"])
    }

    @Test func serviceStartedDependencyDoesNotGate() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                    healthcheck:
                      test: ["CMD", "pg_isready"]
                  app:
                    image: nginx
                    depends_on:
                      db:
                        condition: service_started
                """).toSpecs(project: "p", baseDirectory: nil)
        #expect(result.healthyDeps["app"] == nil)
    }

    @Test func healthyDepWithoutHealthcheckWarns() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                  app:
                    image: nginx
                    depends_on:
                      db:
                        condition: service_healthy
                """).toSpecs(project: "p", baseDirectory: nil)
        // No healthcheck on db → not gated…
        #expect(result.healthyDeps["app"] == nil)
        // …but warned, so the user knows the gate won't fire.
        #expect(result.warnings.contains { $0.contains("service_healthy") } == true)
    }

    @Test func dependsOnListFormHasNoConditions() throws {
        let result = try ComposeParser.parse(
            yaml: """
                services:
                  db:
                    image: postgres
                  app:
                    image: nginx
                    depends_on:
                      - db
                """).toSpecs(project: "p", baseDirectory: nil)
        #expect(result.orderedServices == ["db", "app"])
        #expect(result.healthyDeps["app"] == nil)
    }
}
