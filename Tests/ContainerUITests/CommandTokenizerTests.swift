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

import Testing

@testable import ContainerUI

/// Tests for the shell-style command tokenizer. The quoted-argument cases are the
/// ones that matter: a naive space-split corrupts them, which is the bug that
/// previously broke container creation when a default command was round-tripped.
struct CommandTokenizerTests {

    @Test func emptyInputYieldsNoTokens() {
        #expect(CommandTokenizer.tokenize("") == [])
    }

    @Test func whitespaceOnlyYieldsNoTokens() {
        #expect(CommandTokenizer.tokenize("   \t  ") == [])
    }

    @Test func simpleArgs() {
        #expect(CommandTokenizer.tokenize("sleep infinity") == ["sleep", "infinity"])
    }

    @Test func collapsesRepeatedWhitespace() {
        #expect(CommandTokenizer.tokenize("  nginx   -g    daemon  ") == ["nginx", "-g", "daemon"])
    }

    @Test func doubleQuotesGroupSpaces() {
        // The classic failing case: `daemon off;` must stay one token.
        #expect(CommandTokenizer.tokenize("nginx -g \"daemon off;\"") == ["nginx", "-g", "daemon off;"])
    }

    @Test func singleQuotesGroupSpaces() {
        #expect(CommandTokenizer.tokenize("echo 'hello world'") == ["echo", "hello world"])
    }

    @Test func shDashCWithQuotedScript() {
        #expect(CommandTokenizer.tokenize("sh -c \"echo hi\"") == ["sh", "-c", "echo hi"])
    }

    @Test func backslashEscapesSpaceOutsideQuotes() {
        #expect(CommandTokenizer.tokenize("touch foo\\ bar") == ["touch", "foo bar"])
    }

    @Test func escapedQuoteInsideDoubleQuotes() {
        #expect(CommandTokenizer.tokenize("echo \"a\\\"b\"") == ["echo", "a\"b"])
    }

    @Test func singleQuotesAreLiteral() {
        // No escape processing inside single quotes — backslash is literal.
        #expect(CommandTokenizer.tokenize("echo '\\n'") == ["echo", "\\n"])
    }

    @Test func emptyQuotedStringIsAToken() {
        #expect(CommandTokenizer.tokenize("foo \"\"") == ["foo", ""])
    }

    @Test func unterminatedQuoteCapturesRest() {
        #expect(CommandTokenizer.tokenize("sh -c \"echo hi") == ["sh", "-c", "echo hi"])
    }

    @Test func adjacentQuotedAndUnquotedJoin() {
        #expect(CommandTokenizer.tokenize("a\"b c\"d") == ["ab cd"])
    }
}
