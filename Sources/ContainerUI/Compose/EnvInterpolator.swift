import Foundation

/// Docker-compatible variable interpolation for compose files.
///
/// Compose files routinely reference `${VAR}` values sourced from a `.env` file
/// sitting next to the compose file. Docker substitutes these into the raw text
/// *before* the YAML is parsed, so a value like `POSTGRES_PASSWORD=${DB_PW}` is
/// resolved from the environment table, not left for the parser. This type is that
/// pre-parse text pass — it does not touch `ComposeSpec` / `toSpecs`, so the rest
/// of the pipeline sees already-resolved YAML.
///
/// Distinct from `env_file:` (a per-service list of files injected into a
/// *container's* environment): `.env` feeds interpolation only and never enters a
/// container. This type handles interpolation; `env_file` is not supported.
///
/// Supported forms (matching docker's shell-style syntax):
///   - `${VAR}` / `$VAR` — the value, or "" (plus a warning) if undefined.
///   - `${VAR:-default}` — `default` if VAR is unset *or empty*.
///   - `${VAR-default}`  — `default` if VAR is unset (an empty value is kept).
///   - `${VAR:?message}` — throws if VAR is unset *or empty*.
///   - `${VAR?message}`  — throws if VAR is unset (an empty value is kept).
///   - `$$` — a literal `$` (escape).
/// A variable name is `[A-Za-z_][A-Za-z0-9_]*`; a lone `$` not starting any of the
/// above is left literal.
enum EnvInterpolator {

    // MARK: - Result & errors

    struct Result {
        /// The interpolated text, ready for `ComposeParser.parse`.
        var text: String
        /// One entry per undefined variable substituted with "", for the import
        /// warnings banner. Deduplicated by the caller when merged.
        var warnings: [String]
    }

    /// Thrown for `${VAR:?msg}` / `${VAR?msg}` when the required variable is
    /// missing. Surfaced verbatim through the sheet's `analyzeError` box.
    enum EnvInterpolationError: LocalizedError {
        case requiredVariableMissing(name: String, message: String)

        var errorDescription: String? {
            switch self {
            case .requiredVariableMissing(let name, let message):
                let detail = message.isEmpty ? "" : ": \(message)"
                return "Required variable \"\(name)\" is not set in .env\(detail)."
            }
        }
    }

    // MARK: - Entry points

    /// Host environment as base; `.env` overrides; `PWD` is pinned to the
    /// compose file's directory. This matches docker compose's behaviour where
    /// `${PWD}` is the directory `compose` runs in - for a GUI app launched from
    /// Finder the process PWD is `/`, not the compose file's folder, so the host
    /// `PWD` is meaningless and must be overridden from `baseDirectory`.
    static func interpolate(yaml: String, baseDirectory: URL?) throws -> Result {
        var variables = ProcessInfo.processInfo.environment
        if let baseDirectory {
            variables["PWD"] = baseDirectory.path
        }
        for (key, value) in loadDotEnv(baseDirectory: baseDirectory) {
            variables[key] = value
        }
        return try interpolate(yaml, variables: variables)
    }

    // MARK: - .env loading

    /// Parse `baseDirectory/.env` into a variable table. Missing file → `[:]`.
    ///
    /// Line grammar (a permissive subset of docker's):
    ///   - Blank lines and lines whose first non-space char is `#` are skipped.
    ///   - An optional `export ` prefix is stripped.
    ///   - `KEY=VALUE`; the key is everything before the first `=`, trimmed.
    ///   - A value wrapped in matching single/double quotes is unquoted (its inner
    ///     text kept verbatim, including `#`).
    ///   - An unquoted value has a trailing ` #comment` (a `#` preceded by
    ///     whitespace) stripped, then is trimmed. `KEY=` is a valid empty value.
    static func loadDotEnv(baseDirectory: URL?) -> [String: String] {
        guard let baseDirectory else { return [:] }
        let url = baseDirectory.appending(path: ".env")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var table: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            table[key] = unquoteValue(rawValue)
        }
        return table
    }

    /// Unquote/clean a `.env` value: strip matching wrapping quotes (keeping inner
    /// text verbatim), or for a bare value drop a whitespace-preceded `#comment`.
    private static func unquoteValue(_ raw: String) -> String {
        guard let first = raw.first else { return "" }
        if (first == "\"" || first == "'"), raw.count >= 2, raw.last == first {
            return String(raw.dropFirst().dropLast())
        }
        // Bare value: cut at the first `#` that follows whitespace (inline comment),
        // leaving `pa#ss` intact but dropping `val # note`.
        let chars = Array(raw)
        var cut = chars.count
        var i = 1
        while i < chars.count {
            if chars[i] == "#" && (chars[i - 1] == " " || chars[i - 1] == "\t") {
                cut = i
                break
            }
            i += 1
        }
        return String(chars[0..<cut]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Interpolation

    /// Substitute `${...}` / `$VAR` references in `text` from `variables`.
    static func interpolate(_ text: String, variables: [String: String]) throws -> Result {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)
        var warnings: [String] = []
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            guard ch == "$" else {
                out.append(ch)
                i += 1
                continue
            }

            // `$` at end of text → literal.
            guard i + 1 < chars.count else {
                out.append("$")
                i += 1
                continue
            }

            let next = chars[i + 1]
            if next == "$" {
                // `$$` escape → literal `$`.
                out.append("$")
                i += 2
            } else if next == "{" {
                // Braced `${...}`; find the closing brace.
                guard let close = indexOfClosingBrace(chars, from: i + 2) else {
                    // Unterminated — emit literally and stop treating it as special.
                    out.append("$")
                    i += 1
                    continue
                }
                let content = String(chars[(i + 2)..<close])
                out.append(try resolveBraced(content, variables: variables, warnings: &warnings))
                i = close + 1
            } else if isNameStart(next) {
                // Bare `$VAR`.
                var j = i + 1
                while j < chars.count, isNameChar(chars[j]) { j += 1 }
                let name = String(chars[(i + 1)..<j])
                out.append(lookup(name, variables: variables, warnings: &warnings))
                i = j
            } else {
                // Lone `$` (e.g. `$5`, `$ `) → literal.
                out.append("$")
                i += 1
            }
        }

        return Result(text: out, warnings: warnings)
    }

    // MARK: - Helpers

    /// Resolve the inside of a `${...}` (the braces already stripped).
    private static func resolveBraced(
        _ content: String, variables: [String: String], warnings: inout [String]
    ) throws -> String {
        let chars = Array(content)
        var k = 0
        while k < chars.count, isNameChar(chars[k]) { k += 1 }
        let name = String(chars[0..<k])

        // A malformed reference with no leading name (`${:-x}`) is left literal so
        // it's visible to the user rather than silently dropped.
        guard !name.isEmpty, isNameStartString(name) else {
            warnings.append("Malformed variable reference \"${\(content)}\" left as-is.")
            return "${\(content)}"
        }

        let op = String(chars[k...])  // "", ":-def", "-def", ":?msg", "?msg", …
        let value = variables[name]

        if op.isEmpty {
            return lookup(name, variables: variables, warnings: &warnings)
        }
        if op.hasPrefix(":-") {
            let word = String(op.dropFirst(2))
            return (value?.isEmpty == false) ? value! : word
        }
        if op.hasPrefix("-") {
            let word = String(op.dropFirst(1))
            return value ?? word
        }
        if op.hasPrefix(":?") {
            let msg = String(op.dropFirst(2))
            guard let value, !value.isEmpty else {
                throw EnvInterpolationError.requiredVariableMissing(name: name, message: msg)
            }
            return value
        }
        if op.hasPrefix("?") {
            let msg = String(op.dropFirst(1))
            guard let value else {
                throw EnvInterpolationError.requiredVariableMissing(name: name, message: msg)
            }
            return value
        }
        // Unrecognized operator (`:+`, `=`, …) — not supported; leave literal + warn.
        warnings.append("Unsupported variable operator in \"${\(content)}\" left as-is.")
        return "${\(content)}"
    }

    /// Look up a plain reference; undefined → "" plus a warning.
    private static func lookup(
        _ name: String, variables: [String: String], warnings: inout [String]
    ) -> String {
        if let value = variables[name] { return value }
        warnings.append("Variable \"\(name)\" is not defined in .env — substituted an empty value.")
        return ""
    }

    private static func indexOfClosingBrace(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "}" { return i }
            i += 1
        }
        return nil
    }

    private static func isNameStart(_ c: Character) -> Bool {
        c == "_" || c.isLetter
    }
    private static func isNameChar(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }
    private static func isNameStartString(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        return isNameStart(first)
    }
}
