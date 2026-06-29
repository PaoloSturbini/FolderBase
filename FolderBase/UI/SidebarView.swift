import AppKit
import SwiftUI
import WebKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "Automatico"
        case .light:
            return "Chiaro"
        case .dark:
            return "Scuro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

struct SidebarView: View {
    let selectedFolderURL: URL?
    let recentFolderURLs: [URL]
    let treeRootURL: URL?
    let treeRefreshID: UUID
    @Binding var sidebarFontSize: Double
    @Binding var contentFontSize: Double
    @Binding var appearanceMode: String
    let selectFolder: (URL) -> Void
    let removeFolder: (URL) -> Void
    let chooseFolder: () -> Void
    let navigateTo: (URL) -> Void
    let createItem: (String, String, Bool) -> String?
    let moveItems: ([String], URL) -> Void

    @State private var isShowingSettings = false
    @State private var newItemName = ""
    @State private var newFileExtension = "txt"
    @State private var newItemKind: NewItemKind = .file
    @State private var settingsSection: SettingsSection = .folders
    @State private var creationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Albero e cartelle in uno ScrollView (NON una List): evita i glitch di
            // layout/transizione del NavigationSplitView durante avanti/indietro.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionHeader("Cartelle")

                        if recentFolderURLs.isEmpty {
                            Label("Nessuna cartella", systemImage: "folder")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        } else {
                            ForEach(recentFolderURLs, id: \.path) { folderURL in
                                HStack(spacing: 8) {
                                    Button {
                                        selectFolder(folderURL)
                                    } label: {
                                        Label(folderURL.lastPathComponent, systemImage: selectedFolderURL?.path == folderURL.path ? "folder.fill" : "folder")
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        removeFolder(folderURL)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("Togli cartella")
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                    }

                    if let treeRootURL {
                        VStack(alignment: .leading, spacing: 4) {
                            sectionHeader("Struttura")

                            DirectoryTreeView(
                                rootURL: treeRootURL,
                                selectedFolderURL: selectedFolderURL,
                                fontSize: sidebarFontSize,
                                refreshToken: treeRefreshID,
                                onSelect: navigateTo,
                                onMoveItems: moveItems
                            )
                            .id(treeRootURL.path)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            Divider()

            Button {
                isShowingSettings = true
            } label: {
                Label("Configurazione", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .padding(12)
            .sheet(isPresented: $isShowingSettings) {
                settingsWindow
            }
        }
        .font(.system(size: sidebarFontSize))
        .navigationTitle("FolderBase")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }

    // MARK: - Finestra Configurazione (sidebar + dettaglio, stile Impostazioni di sistema)

    private var settingsWindow: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            settingsDetail
        }
        .frame(width: 780, height: 560)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Configurazione")
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    settingsSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .font(.body)
                            .foregroundStyle(settingsSection == section ? Color.white : Color.accentColor)
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(settingsSection == section ? Color.accentColor : Color.accentColor.opacity(0.12))
                            )

                        Text(section.title)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(settingsSection == section ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(8)
        .frame(width: 220)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var settingsDetail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: settingsSection.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text(settingsSection.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(settingsSection.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Fine") {
                    isShowingSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                Group {
                    switch settingsSection {
                    case .folders:
                        foldersSettings
                    case .appearance:
                        appearanceSettings
                    case .support:
                        supportSettings
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var foldersSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if let selectedFolderURL {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(selectedFolderURL.lastPathComponent)
                                .fontWeight(.medium)
                        }
                        Text(selectedFolderURL.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Label("Nessuna cartella selezionata", systemImage: "folder")
                            .foregroundStyle(.secondary)
                    }

                    Button(action: chooseFolder) {
                        Label("Aggiungi cartella", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel("Cartella corrente", systemImage: "folder")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Tipo", selection: $newItemKind) {
                        ForEach(NewItemKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)

                    HStack(spacing: 10) {
                        TextField("Nome", text: $newItemName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)

                        if newItemKind == .file {
                            TextField("Estensione", text: $newFileExtension)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            if let createdName = createItem(newItemName, newFileExtension, newItemKind == .directory) {
                                creationMessage = "Creato: \(createdName)"
                                newItemName = ""
                            } else {
                                creationMessage = "Creazione non riuscita."
                            }
                        } label: {
                            Label(newItemKind == .directory ? "Crea cartella" : "Crea file", systemImage: newItemKind == .directory ? "folder.badge.plus" : "doc.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedFolderURL == nil || newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let creationMessage {
                            Label(creationMessage, systemImage: creationMessage.contains("non riuscita") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(creationMessage.contains("non riuscita") ? .red : .green)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel("Crea nella cartella corrente", systemImage: "plus.rectangle.on.folder")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if recentFolderURLs.isEmpty {
                        Label("Nessuna cartella", systemImage: "folder")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(recentFolderURLs, id: \.path) { folderURL in
                            HStack(spacing: 8) {
                                Button {
                                    selectFolder(folderURL)
                                } label: {
                                    Label(folderURL.lastPathComponent, systemImage: selectedFolderURL?.path == folderURL.path ? "folder.fill" : "folder")
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    removeFolder(folderURL)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Togli cartella")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel("Cartelle recenti", systemImage: "clock")
            }
        }
    }

    private func settingsCardLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .padding(.bottom, 2)
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Tema", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 340)

                    Text("Segui il sistema oppure forza chiaro/scuro.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel("Tema", systemImage: "circle.lefthalf.filled")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Sidebar")
                            Spacer()
                            Text("\(Int(sidebarFontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $sidebarFontSize, in: 11...22, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Tabella")
                            Spacer()
                            Text("\(Int(contentFontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $contentFontSize, in: 11...24, step: 1)
                    }

                    Button {
                        sidebarFontSize = 13
                        contentFontSize = 13
                    } label: {
                        Label("Ripristina default", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel("Dimensione caratteri", systemImage: "textformat.size")
            }
        }
    }

    private var supportSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Se FolderBase ti è utile, puoi offrirmi un caffè su Ko-fi. Grazie!")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    KofiWidgetView()
                        .frame(width: 240, height: 80)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel("Sostieni lo sviluppo", systemImage: "cup.and.saucer")
            }
        }
    }
}

private struct KofiWidgetView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(html, baseURL: URL(string: "https://storage.ko-fi.com"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    private var html: String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background: transparent;
            }
          </style>
        </head>
        <body>
          <script type='text/javascript' src='https://storage.ko-fi.com/cdn/widget/Widget_2.js'></script>
          <script type='text/javascript'>kofiwidget2.init('Support me on Ko-fi', '#72a4f2', 'S1D521EFNY');kofiwidget2.draw();</script>
        </body>
        </html>
        """
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case folders
    case appearance
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folders:
            return "Cartelle"
        case .appearance:
            return "Aspetto"
        case .support:
            return "Sostieni"
        }
    }

    var systemImage: String {
        switch self {
        case .folders:
            return "folder"
        case .appearance:
            return "paintbrush"
        case .support:
            return "cup.and.saucer"
        }
    }

    var subtitle: String {
        switch self {
        case .folders:
            return "Cartelle monitorate, creazione elementi e recenti"
        case .appearance:
            return "Tema e dimensione dei caratteri"
        case .support:
            return "Offri un contributo allo sviluppo"
        }
    }
}

private enum NewItemKind: String, CaseIterable, Identifiable {
    case file = "File vuoto"
    case directory = "Cartella"

    var id: String { rawValue }
}
