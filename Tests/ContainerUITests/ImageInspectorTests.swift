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

/// Tests for the image-metadata parsing helpers, using real `created_by` history
/// lines and entrypoint snippets captured from nginx/mysql/redis/postgres images.
struct ImageInspectorTests {

    // MARK: EXPOSE parsing (from history created_by)

    @Test func parseExposeSinglePort() {
        let line = "EXPOSE map[80/tcp:{}]"
        #expect(ImageInspector.parseExpose(line) == ["80/tcp"])
    }

    @Test func parseExposeMultiplePorts() {
        let line = "EXPOSE map[3306/tcp:{} 33060/tcp:{}]"
        let result = ImageInspector.parseExpose(line).sorted()
        #expect(result == ["3306/tcp", "33060/tcp"])
    }

    @Test func parseExposeUDP() {
        let line = "EXPOSE map[53/udp:{} 53/tcp:{}]"
        let result = Set(ImageInspector.parseExpose(line))
        #expect(result == ["53/udp", "53/tcp"])
    }

    @Test func parseExposeIgnoresNonExposeLines() {
        #expect(ImageInspector.parseExpose("RUN apt-get install -y foo 80/tcp").isEmpty)
    }

    // MARK: VOLUME parsing

    @Test func parseVolumeSingle() {
        let line = "VOLUME [/var/lib/mysql]"
        #expect(ImageInspector.parseVolume(line) == ["/var/lib/mysql"])
    }

    @Test func parseVolumeMultiple() {
        let line = "VOLUME [/data /config]"
        let result = ImageInspector.parseVolume(line).sorted()
        #expect(result == ["/config", "/data"])
    }

    @Test func parseVolumeIgnoresNonVolumeLines() {
        #expect(ImageInspector.parseVolume("RUN mkdir /var/lib/mysql").isEmpty)
    }

    // MARK: Entrypoint env extraction

    @Test func extractMySQLEnvVars() {
        // Condensed from mysql's docker-entrypoint.sh.
        let script = """
            file_env 'MYSQL_ROOT_PASSWORD'
            file_env 'MYSQL_DATABASE'
            file_env 'MYSQL_USER'
            file_env 'MYSQL_PASSWORD'
            if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
            if [ -n "$MYSQL_ONETIME_PASSWORD" ]; then
            """
        let result = ImageInspector.extractEnvVars(fromScript: script)
        #expect(result.contains("MYSQL_ROOT_PASSWORD"))
        #expect(result.contains("MYSQL_DATABASE"))
        #expect(result.contains("MYSQL_USER"))
        #expect(result.contains("MYSQL_PASSWORD"))
        #expect(result.contains("MYSQL_ALLOW_EMPTY_PASSWORD"))
        #expect(result.contains("MYSQL_RANDOM_ROOT_PASSWORD"))
        #expect(result.contains("MYSQL_ONETIME_PASSWORD"))
    }

    @Test func extractFiltersNoiseAndShellVars() {
        let script = """
            file_env 'MYSQL_ROOT_PASSWORD'
            file_env 'XYZ_DB_PASSWORD'
            if [ -z "$PATH" ]; then
            if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
            """
        let result = ImageInspector.extractEnvVars(fromScript: script)
        #expect(result == ["MYSQL_ROOT_PASSWORD"])
    }

    @Test func extractPostgresEnvVars() {
        let script = """
            file_env 'POSTGRES_PASSWORD'
            file_env 'POSTGRES_USER'
            file_env 'POSTGRES_DB'
            file_env 'POSTGRES_INITDB_ARGS'
            """
        let result = ImageInspector.extractEnvVars(fromScript: script)
        #expect(result.contains("POSTGRES_PASSWORD"))
        #expect(result.contains("POSTGRES_USER"))
        #expect(result.contains("POSTGRES_DB"))
        #expect(result.contains("POSTGRES_INITDB_ARGS"))
    }

    @Test func extractRedisHasNoUserEnv() {
        // redis's entrypoint references no user-facing env vars.
        let script = """
            #!/bin/sh
            set -e
            if [ "${1#-}" != "$1" ]; then
                set -- redis-server "$@"
            fi
            exec "$@"
            """
        #expect(ImageInspector.extractEnvVars(fromScript: script).isEmpty)
    }
}
