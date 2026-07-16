import AppKit
import SwiftUI

/// Vista a board: raggruppa gli elementi nelle colonne definite da un campo Kanban.
/// Trascinando una card da una colonna all'altra si aggiorna il valore del metadata.
struct KanbanBoardView: View {
    let items: [FileItem]
    let field: MetadataField
    let metadataStore: MetadataStore
    let fontSize: Double
    let openItem: (FileItem) -> Void
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var metadataRevision = 0

    private struct Column: Identifiable {
        let id: String
        let assignmentLabel: String   // valore scritto sul drop ("" = senza stato)
        let color: MetadataTagColor
        let items: [FileItem]
        var isUnassigned: Bool { assignmentLabel.isEmpty }
    }

    /// Lo stato Kanban riguarda solo i file: le cartelle non compaiono nella board.
    private var boardItems: [FileItem] {
        items.filter { !$0.isFolder }
    }

    private var columns: [Column] {
        let source = boardItems
        let validLabels = Set(field.options.map(\.label))
        var grouped: [String: [FileItem]] = [:]
        grouped.reserveCapacity(field.options.count + 1)
        for item in source {
            let value = metadataStore.value(for: item, field: field)
            grouped[validLabels.contains(value) ? value : "", default: []].append(item)
        }
        var result: [Column] = [
            Column(
                id: "__unassigned__",
                assignmentLabel: "",
                color: .gray,
                items: grouped[""] ?? []
            )
        ]

        for option in field.options {
            result.append(
                Column(
                    id: option.id,
                    assignmentLabel: option.label,
                    color: option.color,
                    items: grouped[option.label] ?? []
                )
            )
        }

        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column in
                    columnView(column)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(metadataStore.metadataChanges) { _ in metadataRevision &+= 1 }
    }

    private func columnView(_ column: Column) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if column.isUnassigned {
                    Text(L("kanban.unassigned"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                } else {
                    MetadataTagView(label: column.assignmentLabel, color: column.color)
                }

                Spacer()

                Text("\(column.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(column.items) { item in
                        card(item)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(2)
            }
        }
        .frame(width: 250)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: URL.self) { urls, _ in
            applyDrop(paths: urls.map(\.path), toLabel: column.assignmentLabel)
        }
    }

    private func card(_ item: FileItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIconProvider.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: max(fontSize + 3, 16), height: max(fontSize + 3, 16))
            Text(item.name)
                .font(.system(size: fontSize))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.15), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .draggable(item.url)
        .onTapGesture(count: 2) {
            openItem(item)
        }
        .help(item.name)
    }

    private func applyDrop(paths: [String], toLabel label: String) -> Bool {
        // Solo i file possono ricevere uno stato Kanban: le cartelle vengono ignorate.
        let targets = items.filter { paths.contains($0.url.path) && !$0.isFolder }
        guard !targets.isEmpty else { return false }
        metadataStore.updateBulk(items: targets, field: field, value: label)
        return true
    }
}
