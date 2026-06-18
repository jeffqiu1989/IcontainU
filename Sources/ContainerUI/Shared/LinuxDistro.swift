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

import SwiftUI

/// Identifies the Linux distribution behind a machine by parsing its image
/// reference (e.g. `ubuntu:24.04` → Ubuntu 24.04). This is a best-effort
/// heuristic from the image name, not a read of `/etc/os-release`; custom images
/// fall back to showing the repository name.
struct LinuxDistro {
    let name: String
    let version: String?
    /// Brand-ish accent color used for the distro chip.
    let color: Color

    var label: String {
        if let version { return "\(name) \(version)" }
        return name
    }

    /// Known distributions keyed by a substring that appears in the repo name.
    /// Order matters: more specific names first.
    private static let known: [(match: String, name: String, color: Color)] = [
        ("ubuntu", "Ubuntu", .orange),
        ("debian", "Debian", .red),
        ("alpine", "Alpine", Color(red: 0.0, green: 0.6, blue: 0.9)),
        ("fedora", "Fedora", .blue),
        ("rockylinux", "Rocky Linux", .green),
        ("rocky", "Rocky Linux", .green),
        ("almalinux", "AlmaLinux", .red),
        ("alma", "AlmaLinux", .red),
        ("centos", "CentOS", .purple),
        ("archlinux", "Arch Linux", .cyan),
        ("arch", "Arch Linux", .cyan),
        ("opensuse", "openSUSE", .green),
        ("suse", "SUSE", .green),
        ("amazonlinux", "Amazon Linux", .orange),
        ("oraclelinux", "Oracle Linux", .red),
        ("kali", "Kali Linux", .indigo),
        ("busybox", "BusyBox", .gray),
    ]

    init(imageReference: String) {
        let parsed = ParsedImageReference(imageReference)
        let repoLowercased = parsed.repository.lowercased()
        // The distro name is the last path segment (e.g. library/ubuntu → ubuntu).
        let leaf = repoLowercased.split(separator: "/").last.map(String.init) ?? repoLowercased

        if let hit = Self.known.first(where: { leaf.contains($0.match) }) {
            self.name = hit.name
            self.color = hit.color
            // Use the tag as the version when it looks like one (not "latest").
            if let tag = parsed.tag, tag.lowercased() != "latest" {
                self.version = tag
            } else {
                self.version = nil
            }
        } else {
            // Unknown / custom image: show the repo leaf as the name, no version.
            self.name = parsed.repository
            self.color = .secondary
            self.version = nil
        }
    }
}

/// A small chip showing the Linux distribution, colored by brand.
struct DistroChip: View {
    let distro: LinuxDistro

    var body: some View {
        HStack(spacing: 5) {
            Text("🐧")
                .font(.caption2)
            Text(distro.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(distro.color.opacity(0.16), in: Capsule())
        .foregroundStyle(distro.color)
    }
}
