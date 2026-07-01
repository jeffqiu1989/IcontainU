import Foundation
import Testing

@testable import ContainerUI

/// Tests for the pre-parse `${VAR}` interpolation layer and `.env` loading.
struct EnvInterpolatorTests {

    // MARK: - Interpolation forms

    @Test func bracedDefinedVariable() throws {
        let r = try EnvInterpolator.interpolate("a=${FOO}", variables: ["FOO": "bar"])
        #expect(r.text == "a=bar")
        #expect(r.warnings.isEmpty)
    }

    @Test func bareDefinedVariable() throws {
        let r = try EnvInterpolator.interpolate("a=$FOO/b", variables: ["FOO": "bar"])
        // Bare form stops at the first non-name char ("/").
        #expect(r.text == "a=bar/b")
        #expect(r.warnings.isEmpty)
    }

    @Test func undefinedSubstitutesEmptyWithWarning() throws {
        let r = try EnvInterpolator.interpolate("a=${MISSING}", variables: [:])
        #expect(r.text == "a=")
        #expect(r.warnings.count == 1)
        #expect(r.warnings[0].contains("MISSING"))
    }

    @Test func colonDashDefaultUsedWhenUnsetOrEmpty() throws {
        // Unset → default.
        #expect(try EnvInterpolator.interpolate("${X:-def}", variables: [:]).text == "def")
        // Empty → default (the ':' variant treats empty like unset).
        #expect(try EnvInterpolator.interpolate("${X:-def}", variables: ["X": ""]).text == "def")
        // Set & non-empty → the value.
        #expect(try EnvInterpolator.interpolate("${X:-def}", variables: ["X": "v"]).text == "v")
    }

    @Test func dashDefaultKeepsEmptyValue() throws {
        // The non-colon variant only defaults when *unset*; an empty value is kept.
        #expect(try EnvInterpolator.interpolate("${X-def}", variables: [:]).text == "def")
        #expect(try EnvInterpolator.interpolate("${X-def}", variables: ["X": ""]).text == "")
    }

    @Test func requiredMissingThrows() throws {
        #expect(throws: EnvInterpolator.EnvInterpolationError.self) {
            _ = try EnvInterpolator.interpolate("${NEED:?must set}", variables: [:])
        }
        // Empty also trips the colon variant.
        #expect(throws: EnvInterpolator.EnvInterpolationError.self) {
            _ = try EnvInterpolator.interpolate("${NEED:?must set}", variables: ["NEED": ""])
        }
    }

    @Test func requiredPresentDoesNotThrow() throws {
        let r = try EnvInterpolator.interpolate("${NEED:?msg}", variables: ["NEED": "ok"])
        #expect(r.text == "ok")
    }

    @Test func dollarDollarIsLiteralDollar() throws {
        let r = try EnvInterpolator.interpolate(
            #"test: mysqladmin --password="$$(cat /run/secrets/pw)""#, variables: [:])
        // `$$` collapses to a single literal `$`; nothing is treated as a variable.
        #expect(r.text == #"test: mysqladmin --password="$(cat /run/secrets/pw)""#)
        #expect(r.warnings.isEmpty)
    }

    @Test func multipleVariablesOneLine() throws {
        let r = try EnvInterpolator.interpolate(
            "url=${HOST}:${PORT}", variables: ["HOST": "db", "PORT": "5432"])
        #expect(r.text == "url=db:5432")
    }

    @Test func loneDollarIsLiteral() throws {
        let r = try EnvInterpolator.interpolate("cost=$5 and $", variables: [:])
        #expect(r.text == "cost=$5 and $")
        #expect(r.warnings.isEmpty)
    }

    @Test func unterminatedBraceLeftLiteral() throws {
        let r = try EnvInterpolator.interpolate("a=${FOO", variables: ["FOO": "bar"])
        #expect(r.text == "a=${FOO")
    }

    @Test func realWorldEnvironmentBlock() throws {
        // Shape lifted from awesome-compose/postgresql-pgadmin.
        let yaml = """
            environment:
              - POSTGRES_USER=${POSTGRES_USER}
              - POSTGRES_PASSWORD=${POSTGRES_PW}
            """
        let r = try EnvInterpolator.interpolate(
            yaml, variables: ["POSTGRES_USER": "yourUser", "POSTGRES_PW": "changeit"])
        #expect(r.text.contains("POSTGRES_USER=yourUser"))
        #expect(r.text.contains("POSTGRES_PASSWORD=changeit"))
        #expect(!r.text.contains("${"))
    }

    // MARK: - .env loading

    /// Write a `.env` into a fresh temp dir and return the dir URL.
    private func makeEnvDir(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "icontainu-env-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(to: dir.appending(path: ".env"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func loadDotEnvParsesLines() throws {
        let dir = try makeEnvDir("""
            # a full-line comment
            POSTGRES_USER=yourUser
            POSTGRES_PW=changeit
            EMPTY=
            export EXPORTED=yes
            VPN=your-domain.com # inline comment stripped
            QUOTED="quoted value"
            SINGLE='single value'
            HASH_IN_VALUE=pa#ss

            """)
        defer { try? FileManager.default.removeItem(at: dir) }

        let table = EnvInterpolator.loadDotEnv(baseDirectory: dir)
        #expect(table["POSTGRES_USER"] == "yourUser")
        #expect(table["POSTGRES_PW"] == "changeit")
        #expect(table["EMPTY"] == "")
        #expect(table["EXPORTED"] == "yes")
        // Whitespace-preceded `#` is an inline comment and is dropped.
        #expect(table["VPN"] == "your-domain.com")
        // Wrapping quotes are stripped, inner text kept.
        #expect(table["QUOTED"] == "quoted value")
        #expect(table["SINGLE"] == "single value")
        // A `#` not preceded by whitespace is part of the value.
        #expect(table["HASH_IN_VALUE"] == "pa#ss")
    }

    @Test func loadDotEnvMissingFileIsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "icontainu-noenv-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(EnvInterpolator.loadDotEnv(baseDirectory: dir).isEmpty)
    }

    @Test func loadDotEnvNilDirectoryIsEmpty() throws {
        #expect(EnvInterpolator.loadDotEnv(baseDirectory: nil).isEmpty)
    }

    @Test func endToEndFromDirectory() throws {
        let dir = try makeEnvDir("FOO=resolved\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try EnvInterpolator.interpolate(yaml: "value=${FOO}", baseDirectory: dir)
        #expect(r.text == "value=resolved")
        #expect(r.warnings.isEmpty)
    }
}
