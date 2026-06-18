//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

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
}
