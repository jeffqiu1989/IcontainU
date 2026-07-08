import Foundation

/// Splits a command line into argv tokens with shell-style quoting, so that a
/// user typing `sh -c "echo hi"` yields three tokens (`sh`, `-c`, `echo hi`)
/// rather than splitting inside the quotes. A naive `split(separator: " ")` would
/// corrupt quoted arguments — exactly the bug that broke container creation
/// before — so this is used whenever the user has typed a custom command.
///
/// Supported quoting:
///   - Double quotes `"..."` group text and allow backslash escapes (`\"`, `\\`).
///   - Single quotes `'...'` group text literally (no escapes inside).
///   - A backslash outside quotes escapes the next character.
/// Unterminated quotes are tolerated: the run captured so far becomes a token.
enum CommandTokenizer {
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false

        enum State {
            case normal
            case inDouble
            case inSingle
        }
        var state: State = .normal
        var iterator = input.makeIterator()

        func flush() {
            if hasCurrent {
                tokens.append(current)
                current = ""
                hasCurrent = false
            }
        }

        while let ch = iterator.next() {
            switch state {
            case .normal:
                switch ch {
                case " ", "\t", "\n":
                    flush()
                case "\"":
                    hasCurrent = true
                    state = .inDouble
                case "'":
                    hasCurrent = true
                    state = .inSingle
                case "\\":
                    // Escape the next character literally.
                    if let next = iterator.next() {
                        current.append(next)
                        hasCurrent = true
                    }
                default:
                    current.append(ch)
                    hasCurrent = true
                }
            case .inDouble:
                switch ch {
                case "\"":
                    state = .normal
                case "\\":
                    // Inside double quotes, a backslash escapes the next char.
                    if let next = iterator.next() {
                        current.append(next)
                    }
                default:
                    current.append(ch)
                }
            case .inSingle:
                // Single quotes are literal — no escapes.
                if ch == "'" {
                    state = .normal
                } else {
                    current.append(ch)
                }
            }
        }

        flush()
        return tokens
    }

    /// The inverse of `tokenize`: join an argv back into a single command-line
    /// string that `tokenize` can round-trip losslessly. An element containing
    /// whitespace, newlines, or quote/backslash characters is wrapped in double
    /// quotes with `\` and `"` backslash-escaped — double quotes preserve
    /// newlines (and single quotes) literally, so a multi-line `sh -c` script
    /// survives the form's text-field round-trip instead of being split into
    /// separate argv tokens (which turned `for…do…break\nsleep 1\ndone` into a
    /// syntax-error shell script).
    static func join(_ tokens: [String]) -> String {
        tokens.map { token in
            let needsQuoting = token.isEmpty || token.contains { ch in
                ch == " " || ch == "\t" || ch == "\n" || ch == "'" || ch == "\"" || ch == "\\"
            }
            guard needsQuoting else { return token }
            let escaped = token
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " ")
    }
}
