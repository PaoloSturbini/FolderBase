import SwiftUI

struct SidebarView: View {
    let selectedFolderURL: URL?
    let recentFolderURLs: [URL]
    let treeRootURL: URL?
    @Binding var sidebarFontSize: Double
    @Binding var contentFontSize: Double
    let selectFolder: (URL) -> Void
    let removeFolder: (URL) -> Void
    let chooseFolder: () -> Void
    let navigateTo: (URL) -> Void

    @State private var isShowingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: chooseFolder) {
                Label("Scegli cartella", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            List {
                Section("Cartelle") {
                    if recentFolderURLs.isEmpty {
                        Label("Nessuna cartella", systemImage: "folder")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentFolderURLs, id: \.path) { folderURL in
                            HStack(spacing: 8) {
                                Button {
                                    selectFolder(folderURL)
                                } label: {
                                    Label(folderURL.lastPathComponent, systemImage: selectedFolderURL?.path == folderURL.path ? "folder.fill" : "folder")
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    removeFolder(folderURL)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Togli cartella")
                            }
                        }
                    }
                }

                if let treeRootURL {
                    Section("Struttura") {
                        DirectoryTreeView(
                            rootURL: treeRootURL,
                            selectedFolderURL: selectedFolderURL,
                            fontSize: sidebarFontSize,
                            onSelect: navigateTo
                        )
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                isShowingSettings.toggle()
            } label: {
                Label("Configurazione", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 12)
            .popover(isPresented: $isShowingSettings, arrowEdge: .top) {
                settingsPopover
            }
        }
        .font(.system(size: sidebarFontSize))
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .navigationTitle("FolderBase")
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dimensione caratteri")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Sidebar: \(Int(sidebarFontSize)) pt")
                    .foregroundStyle(.secondary)
                Slider(value: $sidebarFontSize, in: 11...22, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tabella: \(Int(contentFontSize)) pt")
                    .foregroundStyle(.secondary)
                Slider(value: $contentFontSize, in: 11...24, step: 1)
            }

            Divider()

            Button("Ripristina dimensioni") {
                sidebarFontSize = 14
                contentFontSize = 16
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}
