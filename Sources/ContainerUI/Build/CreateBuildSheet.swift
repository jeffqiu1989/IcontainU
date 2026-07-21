import AppKit
import SwiftUI

/// Single-page sectioned form to create or edit a build config. The user picks
/// a build context directory (the Dockerfile is auto-detected under it), gives
/// the result at least one readable tag, and optionally sets a target platform,
/// build-args, labels, and cache/pull options.
///
/// Saving persists a `BuildConfigRecord` (the card); "Save & Build" additionally
/// starts the build, whose progress and log show in the Build section behind
/// this sheet.
struct CreateBuildSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var form = BuildFormState()

    /// Record being edited; nil = creating a new config.
    let existing: BuildConfigRecord?
    /// Names already taken by other configs (new-config name collision check).
    let takenNames: Set<String>
    /// Called with the assembled record and whether to build immediately.
    let onSave: (BuildConfigRecord, _ buildNow: Bool) -> Void

    /// The config name: derived from the primary tag ("myapp:latest" -> "myapp").
    private var derivedName: String {
        if let existing { return existing.name }
        let tag = form.tags.first?.trimmed ?? ""
        let base = tag.split(separator: ":").first.map(String.init) ?? tag
        return base.split(separator: "/").last.map(String.init) ?? base
    }

    /// A new config must not collide with an existing card's name.
    private var nameCollides: Bool {
        existing == nil && takenNames.contains(derivedName)
    }

    var body: some View {
        FormSheet(
            icon: "hammer",
            iconColor: Palette.build,
            title: existing == nil ? "New Build Config" : "Edit Build Config",
            subtitle: "Builds from a Dockerfile via the shared builder.",
            width: .wide,
            height: 620
        ) {
            dockerfileSection
            tagsSection
            platformSection
            optionsSection
            if nameCollides {
                Text("A build config named \"\(derivedName)\" already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(makeRecord(), false)
                dismiss()
            }
            .disabled(!form.isValid || nameCollides)
            Button("Save & Build") {
                onSave(makeRecord(), true)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!form.isValid || nameCollides)
        }
        .onAppear {
            if let existing { form.apply(record: existing) }
        }
    }

    /// Assemble the persisted record from the form (preserving identity fields
    /// when editing).
    private func makeRecord() -> BuildConfigRecord {
        let spec = form.makeSpec()
        return BuildConfigRecord(
            name: derivedName,
            contextDirPath: spec.contextDir.path,
            dockerfilePath: spec.dockerfilePath.path,
            tags: spec.tags,
            platforms: spec.platforms.map(\.description),
            noCache: spec.noCache,
            buildArgs: spec.buildArgs,
            target: spec.target,
            labels: spec.labels,
            pull: spec.pull,
            source: existing?.source ?? .standalone,
            createdAt: existing?.createdAt ?? Date(),
            lastBuild: existing?.lastBuild)
    }

    // MARK: Three-column form row

    /// Fixed label column (right-aligned) so every row's content starts at the
    /// same x; fixed accessory column so the middle stays a constant width whether
    /// a row carries a +/- button or blank. This is the "三段式" layout: label |
    /// content | accessory-or-blank.
    private static let labelColumn: CGFloat = 84
    private static let accessoryColumn: CGFloat = 24

    /// One aligned form row. Pass `nil` for `label` on continuation rows of a
    /// multi-row section so the content column still lines up under the first row.
    @ViewBuilder
    private func formRow<C: View, A: View>(
        _ label: LocalizedStringKey?,
        verticalAlignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> C,
        @ViewBuilder accessory: () -> A
    ) -> some View {
        HStack(alignment: verticalAlignment, spacing: 10) {
            // Always a real (possibly empty) Text so the fixed-width label column
            // is reserved even on continuation rows (label == nil). An empty Group
            // collapses on macOS 26 and lets the content slide left under the label.
            Text(label ?? "")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: Self.labelColumn, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)

            accessory()
                .frame(width: Self.accessoryColumn, alignment: .center)
        }
    }

    /// A caption aligned under the content column (blank label + accessory).
    private func captionRow(_ text: LocalizedStringKey) -> some View {
        formRow(nil) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } accessory: { EmptyView() }
    }

    // MARK: Dockerfile (context derived)

    private var dockerfileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            formRow("Dockerfile") {
                TextField("path to Dockerfile", text: $form.dockerfilePath)
                    .textFieldStyle(.roundedBorder)
            } accessory: {
                Button { chooseDockerfile() } label: { Image(systemName: "doc") }
                    .buttonStyle(.borderless)
                    .help("Choose the Dockerfile")
            }
            // Context is derived from the Dockerfile's directory (read-only) -
            // standalone builds use the Dockerfile's folder as context, like
            // `docker build`'s default.
            if !form.contextPath.isEmpty {
                formRow(nil) {
                    HStack(spacing: 4) {
                        Text("Context")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(form.contextPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                } accessory: { EmptyView() }
            }
        }
    }

    // MARK: Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array($form.tags.enumerated()), id: \.element.id) { index, $row in
                formRow(index == 0 ? "Tags" : nil) {
                    TextField("name:tag  (e.g. myapp:latest)", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                } accessory: {
                    rowControl(isFirst: index == 0) {
                        form.tags.append(TagRow())
                    } onRemove: {
                        removeTag(row.id)
                    }
                }
            }
            captionRow("At least one tag is required.")
        }
    }

    /// Remove a tag row by id, keeping at least one row so the editor always
    /// shows a fillable line. Extracted (not inline in the ForEach) to mirror
    /// `CreateContainerSheet.removeNetwork`: mutating an `@Observable` array
    /// from an inline closure that also reads the array trips the observation
    /// registrar; routing through a method that takes the plain id avoids it.
    private func removeTag(_ id: TagRow.ID) {
        form.tags.removeAll { $0.id == id }
        if form.tags.isEmpty { form.tags = [TagRow()] }
    }

    // MARK: Platform

    private var platformSection: some View {
        formRow("Platform") {
            HStack(spacing: 20) {
                Toggle("ARM64", isOn: $form.arm64)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Toggle("AMD64 (x86_64)", isOn: $form.amd64)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Spacer(minLength: 0)
            }
        } accessory: { EmptyView() }
    }

    // MARK: Options (always visible)

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            formRow("Options", verticalAlignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    optionToggle("No cache", isOn: $form.noCache)
                    optionToggle("Always pull base image", isOn: $form.pull)
                }
            } accessory: { EmptyView() }
            if form.noCache {
                // noCache drives the builder lifecycle too: a no-cache build
                // deletes the builder afterward (no cache worth keeping), so disk
                // doesn't grow. Cached builds keep the builder for fast rebuilds.
                captionRow("Also removes the builder after the build to keep disk clean.")
            }
        }
    }

    /// A label + switch row with a fixed-width label column so the two option
    /// switches line up vertically (their labels differ in length).
    private func optionToggle(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 180, alignment: .leading)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
            Spacer(minLength: 0)
        }
    }

    // MARK: Row control (matches CreateContainerSheet)

    @ViewBuilder
    private func rowControl(
        isFirst: Bool, onAdd: @escaping () -> Void, onRemove: @escaping () -> Void
    ) -> some View {
        if isFirst {
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Palette.networks)
            }
            .buttonStyle(.borderless)
            .help("Add a row")
        } else {
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Pickers

    private func chooseDockerfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Context derives from the Dockerfile's directory, so setting the
        // Dockerfile is all that's needed.
        form.dockerfilePath = url.path(percentEncoded: false)
    }

}
