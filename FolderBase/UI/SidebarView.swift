import SwiftUI

struct SidebarView: View {
    var body: some View {
        List {
            Section("Favorites") {
                Label("Desktop", systemImage: "folder.fill")
                Label("Documents", systemImage: "folder.fill")
                Label("Downloads", systemImage: "folder.fill")
            }

            Section("Macintosh HD") {
                Label("Applications", systemImage: "folder.fill")
                Label("Users", systemImage: "folder.fill")
            }
        }
        .navigationTitle("FolderBase")
    }
}
