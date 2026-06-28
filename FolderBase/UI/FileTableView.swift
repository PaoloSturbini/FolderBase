import SwiftUI

struct FileTableView: View {
    @State private var items: [FileItem] = FileItem.sample

    var body: some View {
        Table(items) {
            TableColumn("Name") { item in
                HStack {
                    Image(systemName: item.isFolder ? "folder.fill" : "doc.fill")
                    Text(item.name)
                }
            }
            TableColumn("Type", value: \.type)
            TableColumn("Created", value: \.createdDescription)
            TableColumn("Size", value: \.sizeDescription)
            TableColumn("Nota", value: \.note)
            TableColumn("Stato", value: \.status)
        }
        .navigationTitle("Desktop")
    }
}
