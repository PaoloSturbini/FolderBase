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
            return L("appearance.system")
        case .light:
            return L("appearance.light")
        case .dark:
            return L("appearance.dark")
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
    @ObservedObject var templateStore: TemplateStore
    @ObservedObject var metadataStore: MetadataStore
    @ObservedObject private var loc = LocalizationManager.shared

    @State private var isShowingSettings = false
    @State private var isAddingTemplate = false
    @State private var templatePendingEdit: MetadataTemplate?
    @State private var maintenanceMessage: String?
    @State private var maintenanceOrphans = 0
    @AppStorage("autoPurgeOrphans") private var autoPurgeOrphans = false
    @State private var newItemName = ""
    @State private var newFileExtension = "txt"
    @State private var newItemKind: NewItemKind = .file
    @State private var settingsSection: SettingsSection = .folders
    @State private var creationMessage: String?
    @State private var creationFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Albero e cartelle in uno ScrollView (NON una List): evita i glitch di
            // layout/transizione del NavigationSplitView durante avanti/indietro.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionHeader(L("sidebar.folders"))

                        if recentFolderURLs.isEmpty {
                            Label(L("common.noFolders"), systemImage: "folder")
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
                                    .help(L("sidebar.removeFolder"))
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                    }

                    if let treeRootURL {
                        VStack(alignment: .leading, spacing: 4) {
                            sectionHeader(L("sidebar.structure"))

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
                Label(L("sidebar.configuration"), systemImage: "gearshape")
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
        .frame(width: 760, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isAddingTemplate) {
            TemplateEditorView(title: L("templateEditor.new")) { template in
                templateStore.add(template)
                isAddingTemplate = false
            } cancel: {
                isAddingTemplate = false
            }
        }
        .sheet(item: $templatePendingEdit) { template in
            TemplateEditorView(title: L("templateEditor.edit"), template: template) { updated in
                templateStore.update(updated)
                templatePendingEdit = nil
            } cancel: {
                templatePendingEdit = nil
            }
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("sidebar.configuration"))
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 16)
                .padding(.bottom, 10)

            ForEach(SettingsSection.allCases) { section in
                let isSelected = settingsSection == section
                Button {
                    settingsSection = section
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.systemImage)
                            .font(.body)
                            .frame(width: 20)
                            .foregroundStyle(isSelected ? Color.white : Color.accentColor)

                        Text(section.title)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(8)
        .frame(width: 210)
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

                Button(L("common.done")) {
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
                    case .language:
                        languageSettings
                    case .templates:
                        templatesSettings
                    case .maintenance:
                        maintenanceSettings
                    case .help:
                        helpSettings
                    case .support:
                        supportSettings
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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
                        Label(L("folders.none"), systemImage: "folder")
                            .foregroundStyle(.secondary)
                    }

                    Button(action: chooseFolder) {
                        Label(L("folders.addFolder"), systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("folders.currentCard"), systemImage: "folder")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(L("common.type"), selection: $newItemKind) {
                        ForEach(NewItemKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)

                    HStack(spacing: 10) {
                        TextField(L("common.name"), text: $newItemName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)

                        if newItemKind == .file {
                            TextField(L("folders.extension"), text: $newFileExtension)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            if let createdName = createItem(newItemName, newFileExtension, newItemKind == .directory) {
                                creationFailed = false
                                creationMessage = "\(L("folders.createdPrefix")) \(createdName)"
                                newItemName = ""
                            } else {
                                creationFailed = true
                                creationMessage = L("folders.createFailed")
                            }
                        } label: {
                            Label(newItemKind == .directory ? L("folders.createFolder") : L("folders.createFile"), systemImage: newItemKind == .directory ? "folder.badge.plus" : "doc.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedFolderURL == nil || newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let creationMessage {
                            Label(creationMessage, systemImage: creationFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(creationFailed ? .red : .green)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("folders.createCard"), systemImage: "plus.rectangle.on.folder")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if recentFolderURLs.isEmpty {
                        Label(L("common.noFolders"), systemImage: "folder")
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
                settingsCardLabel(L("folders.recentCard"), systemImage: "clock")
            }
        }
    }

    private var maintenanceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("maint.intro"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button {
                            let result = metadataStore.reconcileManagedFiles()
                            maintenanceOrphans = result.missing
                            maintenanceMessage = "\(L("maint.updated")) \(result.relocated) · \(L("maint.orphans")) \(result.missing)"
                        } label: {
                            Label(L("maint.repair"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        if maintenanceOrphans > 0 {
                            Button(role: .destructive) {
                                let removed = metadataStore.purgeOrphans()
                                maintenanceOrphans = 0
                                maintenanceMessage = "\(L("maint.removedPrefix")) \(removed) \(L("maint.orphanMetadataSuffix"))"
                            } label: {
                                Label("\(L("maint.removePrefix")) \(maintenanceOrphans) \(L("maint.orphans"))", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let maintenanceMessage {
                            Text(maintenanceMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("maint.repairCard"), systemImage: "arrow.triangle.2.circlepath")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L("maint.autoToggle"), isOn: $autoPurgeOrphans)
                        .toggleStyle(.checkbox)

                    Text(L("maint.autoNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("maint.autoCard"), systemImage: "trash")
            }
        }
    }

    private var helpSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("help.intro"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        HelpService.openGuide(language: loc.language)
                    } label: {
                        Label(L("help.open"), systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text(L("help.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("help.card"), systemImage: "questionmark.circle")
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
                    Picker(L("appearance.themeCard"), selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 340)

                    Text(L("appearance.themeNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("appearance.themeCard"), systemImage: "circle.lefthalf.filled")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("appearance.sidebar"))
                            Spacer()
                            Text("\(Int(sidebarFontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $sidebarFontSize, in: 11...22, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("appearance.table"))
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
                        Label(L("appearance.resetDefault"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("appearance.fontCard"), systemImage: "textformat.size")
            }
        }
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L("language.label"), selection: Binding(
                        get: { loc.language },
                        set: { loc.language = $0 }
                    )) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 340)

                    Text(L("language.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("language.card"), systemImage: "globe")
            }
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build:
            return "\(L("about.versionPrefix")) \(short) (\(build))"
        case let (short?, _):
            return "\(L("about.versionPrefix")) \(short)"
        case let (_, build?):
            return "\(L("about.versionPrefix")) \(build)"
        default:
            return L("about.devVersion")
        }
    }

    private var templatesSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if templateStore.templates.isEmpty {
                        Text(L("templates.emptyNote"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(templateStore.templates) { template in
                            HStack(spacing: 10) {
                                Image(systemName: "rectangle.stack")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(template.name)
                                        .fontWeight(.medium)
                                    Text(columnsSummary(template))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)

                                Button {
                                    templatePendingEdit = template
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help(L("templates.editTemplate"))

                                Button {
                                    templateStore.delete(id: template.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help(L("templates.deleteTemplate"))
                            }
                            .padding(.vertical, 2)

                            if template.id != templateStore.templates.last?.id {
                                Divider()
                            }
                        }
                    }

                    Divider()

                    Button {
                        isAddingTemplate = true
                    } label: {
                        Label(L("templates.newTemplate"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("templates.card"), systemImage: "rectangle.stack")
            }

            Text(L("templates.footerNote"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func columnsSummary(_ template: MetadataTemplate) -> String {
        guard !template.fields.isEmpty else { return L("templates.noColumns") }
        return template.fields.map(\.name).joined(separator: ", ")
    }

    private var supportSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("FolderBase")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text(appVersionString)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(L("about.tagline"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("about.info"), systemImage: "info.circle")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("about.supportText"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    KofiWidgetView()
                        .frame(width: 240, height: 56)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("about.supportCard"), systemImage: "cup.and.saucer")
            }
        }
    }
}

/// Mostra il bottone ufficiale del widget Ko-fi e, al clic, apre la pagina Ko-fi nel
/// browser di sistema invece di navigare dentro la web view (che non funzionava).
private struct KofiWidgetView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: URL(string: "https://storage.ko-fi.com"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let target = URL(string: "https://ko-fi.com/s/d68bf91199")!

        // Clic sul bottone del widget: apri nel browser e annulla la navigazione interna.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                openExternally(navigationAction.request.url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        // Il widget apre il link con target=_blank → gestiamo anche la richiesta di nuova finestra.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            openExternally(navigationAction.request.url)
            return nil
        }

        private func openExternally(_ url: URL?) {
            // Qualunque clic sul widget apre sempre la pagina Ko-fi dedicata.
            NSWorkspace.shared.open(target)
        }
    }

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
    case language
    case templates
    case maintenance
    case help
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folders:
            return L("settings.folders.title")
        case .appearance:
            return L("settings.appearance.title")
        case .language:
            return L("settings.language.title")
        case .templates:
            return L("settings.templates.title")
        case .maintenance:
            return L("settings.maintenance.title")
        case .help:
            return L("settings.help.title")
        case .support:
            return L("settings.support.title")
        }
    }

    var systemImage: String {
        switch self {
        case .folders:
            return "folder"
        case .appearance:
            return "paintbrush"
        case .language:
            return "globe"
        case .templates:
            return "rectangle.stack"
        case .maintenance:
            return "wrench.and.screwdriver"
        case .help:
            return "questionmark.circle"
        case .support:
            return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .folders:
            return L("settings.folders.subtitle")
        case .appearance:
            return L("settings.appearance.subtitle")
        case .language:
            return L("settings.language.subtitle")
        case .templates:
            return L("settings.templates.subtitle")
        case .maintenance:
            return L("settings.maintenance.subtitle")
        case .help:
            return L("settings.help.subtitle")
        case .support:
            return L("settings.support.subtitle")
        }
    }
}

private enum NewItemKind: String, CaseIterable, Identifiable {
    case file
    case directory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file:
            return L("newItem.file")
        case .directory:
            return L("newItem.directory")
        }
    }
}
