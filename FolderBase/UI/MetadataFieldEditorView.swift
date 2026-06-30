import SwiftUI

/// Editor di un singolo campo metadata (nome + tipo + eventuali opzioni colorate).
/// Condiviso tra la tabella (aggiunta/modifica colonna) e l'editor dei template.
struct MetadataFieldEditorView: View {
    let title: String
    var save: (String, MetadataFieldKind, [MetadataSelectOption]) -> Void
    var cancel: () -> Void

    @ObservedObject private var loc = LocalizationManager.shared
    @State private var name = ""
    @State private var kind: MetadataFieldKind = .text
    @State private var newOptionLabel = ""
    @State private var newOptionColor: MetadataTagColor = .blue
    @State private var options: [MetadataSelectOption] = []

    init(title: String, field: MetadataField? = nil, save: @escaping (String, MetadataFieldKind, [MetadataSelectOption]) -> Void, cancel: @escaping () -> Void) {
        self.title = title
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: field?.name ?? "")
        _kind = State(initialValue: field?.kind ?? .text)
        _options = State(initialValue: field?.options ?? [])
    }

    private var isCreating: Bool {
        // Vale per entrambe le lingue ("Nuov…" / "New…").
        title.localizedCaseInsensitiveContains("nuov") || title.localizedCaseInsensitiveContains("new")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            TextField(L("field.nameColumn"), text: $name)

            Picker(L("common.type"), selection: $kind) {
                ForEach(MetadataFieldKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            if kind.usesOptions {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("field.values"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("field.newState"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                TextField(L("field.stateName"), text: $newOptionLabel)
                                    .frame(minWidth: 260)
                                    .onSubmit {
                                        addOption()
                                    }

                                Picker(L("common.color"), selection: $newOptionColor) {
                                    ForEach(MetadataTagColor.allCases) { color in
                                        ColorSwatchLabel(color: color)
                                            .tag(color)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if options.isEmpty {
                        Text(L("field.noState"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(options) { option in
                                HStack(spacing: 8) {
                                    TextField(L("common.value"), text: optionLabelBinding(option))
                                        .frame(minWidth: 260)
                                        .onSubmit {
                                            normalizeOptions()
                                        }

                                    Picker(L("common.color"), selection: optionColorBinding(option)) {
                                        ForEach(MetadataTagColor.allCases) { color in
                                            ColorSwatchLabel(color: color)
                                                .tag(color)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 150)

                                    Button {
                                        removeOption(option)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            HStack {
                Spacer()

                Button(L("common.cancel"), action: cancel)

                Button(isCreating ? L("common.add") : L("common.save")) {
                    let normalizedOptions = selectableOptions
                    options = normalizedOptions
                    save(name, kind, normalizedOptions)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: kind) {
            applyDefaultsForKind()
        }
    }

    private var selectableOptions: [MetadataSelectOption] {
        kind.usesOptions ? normalizedEditorOptions() : []
    }

    private func addOption() {
        let label = newOptionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              !options.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else { return }

        options.append(MetadataSelectOption(label: label, color: newOptionColor))
        newOptionLabel = ""
    }

    private func removeOption(_ option: MetadataSelectOption) {
        options.removeAll { $0.id == option.id }
    }

    private func normalizeOptions() {
        options = normalizedEditorOptions()
    }

    private func normalizedEditorOptions() -> [MetadataSelectOption] {
        var seenLabels: Set<String> = []
        return options.compactMap { option in
            let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !seenLabels.contains(label.lowercased()) else { return nil }
            seenLabels.insert(label.lowercased())
            return MetadataSelectOption(id: option.id, label: label, color: option.color)
        }
    }

    private func optionLabelBinding(_ option: MetadataSelectOption) -> Binding<String> {
        Binding(
            get: {
                options.first { $0.id == option.id }?.label ?? ""
            },
            set: { newValue in
                guard let index = options.firstIndex(where: { $0.id == option.id }) else { return }
                options[index].label = newValue
            }
        )
    }

    private func optionColorBinding(_ option: MetadataSelectOption) -> Binding<MetadataTagColor> {
        Binding(
            get: {
                options.first { $0.id == option.id }?.color ?? .gray
            },
            set: { newValue in
                guard let index = options.firstIndex(where: { $0.id == option.id }) else { return }
                options[index].color = newValue
            }
        )
    }

    private func applyDefaultsForKind() {
        switch kind {
        case .kanban:
            // ToDo in rosso (richiesta utente), poi Doing/Done.
            options = [
                MetadataSelectOption(label: "ToDo", color: .red),
                MetadataSelectOption(label: "Doing", color: .blue),
                MetadataSelectOption(label: "Done", color: .green)
            ]
        case .select, .text, .link, .number, .date:
            options = []
        }
    }
}

struct ColorSwatchLabel: View {
    let color: MetadataTagColor
    var showsTitle = true

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.swiftUIColor)
                .frame(width: 16, height: 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                }

            if showsTitle {
                Text(color.title)
            }
        }
    }
}
