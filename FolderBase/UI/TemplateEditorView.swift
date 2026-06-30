import SwiftUI

/// Editor di un template: nome + elenco ordinato di campi (nome/tipo/opzioni).
/// I singoli campi si aggiungono/modificano riutilizzando `MetadataFieldEditorView`.
struct TemplateEditorView: View {
    let title: String
    var save: (MetadataTemplate) -> Void
    var cancel: () -> Void

    @State private var templateID: String
    @State private var name: String
    @State private var fields: [FieldTemplate]
    @State private var isAddingField = false
    @State private var fieldPendingEdit: FieldTemplate?

    init(title: String, template: MetadataTemplate? = nil, save: @escaping (MetadataTemplate) -> Void, cancel: @escaping () -> Void) {
        self.title = title
        self.save = save
        self.cancel = cancel
        _templateID = State(initialValue: template?.id ?? UUID().uuidString)
        _name = State(initialValue: template?.name ?? "")
        _fields = State(initialValue: template?.fields ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            TextField("Nome template", text: $name)
                .textFieldStyle(.roundedBorder)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if fields.isEmpty {
                        Text("Nessun campo. Aggiungi le colonne che questo template deve generare.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(fields) { field in
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: field.kind))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(field.name)
                                    Text(field.kind.rawValue + optionsSummary(field))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                Button {
                                    fieldPendingEdit = field
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Modifica campo")

                                Button {
                                    fields.removeAll { $0.id == field.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Rimuovi campo")
                            }
                            .padding(.vertical, 2)

                            if field.id != fields.last?.id {
                                Divider()
                            }
                        }
                    }

                    Divider()

                    Button {
                        isAddingField = true
                    } label: {
                        Label("Aggiungi campo", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                Label("Campi", systemImage: "list.bullet.rectangle")
                    .font(.headline)
            }

            HStack {
                Spacer()
                Button("Annulla", action: cancel)
                Button(title.localizedCaseInsensitiveContains("nuov") ? "Crea" : "Salva") {
                    save(MetadataTemplate(id: templateID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), fields: fields))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fields.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .sheet(isPresented: $isAddingField) {
            MetadataFieldEditorView(title: "Nuovo campo") { fieldName, kind, options in
                fields.append(FieldTemplate(name: fieldName, kind: kind, options: options))
                isAddingField = false
            } cancel: {
                isAddingField = false
            }
        }
        .sheet(item: $fieldPendingEdit) { field in
            MetadataFieldEditorView(
                title: "Modifica campo",
                field: MetadataField(id: field.id, name: field.name, kind: field.kind, options: field.options)
            ) { fieldName, kind, options in
                if let index = fields.firstIndex(where: { $0.id == field.id }) {
                    fields[index] = FieldTemplate(id: field.id, name: fieldName, kind: kind, options: options)
                }
                fieldPendingEdit = nil
            } cancel: {
                fieldPendingEdit = nil
            }
        }
    }

    private func optionsSummary(_ field: FieldTemplate) -> String {
        guard field.kind.usesOptions, !field.options.isEmpty else { return "" }
        return " · " + field.options.map(\.label).joined(separator: ", ")
    }

    private func icon(for kind: MetadataFieldKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .number: return "number"
        case .date: return "calendar"
        case .kanban: return "rectangle.split.3x1"
        case .select: return "tag"
        case .link: return "link"
        }
    }
}
