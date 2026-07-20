import AppKit
import SwiftUI
import UniformTypeIdentifiers
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

/// Colore d'accento dell'app, scelto dall'utente. È il colore usato per le barre di selezione
/// (albero, nota selezionata) e per i controlli standard (via `.tint`). Persistito in AppStorage.
enum AppAccentColor: String, CaseIterable, Identifiable {
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite

    var id: String { rawValue }

    static let storageKey = "appAccentColor"
    /// Valore speciale di `storageKey` che indica un colore personalizzato (letto da `customHexKey`).
    static let customRaw = "custom"
    static let customHexKey = "appAccentCustomHex"

    var color: Color {
        switch self {
        case .blue:
            return .blue
        case .purple:
            return .purple
        case .pink:
            return .pink
        case .red:
            return .red
        case .orange:
            return .orange
        case .yellow:
            return .yellow
        case .green:
            return .green
        case .graphite:
            return Color(nsColor: .systemGray)
        }
    }

    /// Titolo localizzato (riusa le chiavi dei colori dei tag).
    var title: String {
        switch self {
        case .blue:
            return L("tagColor.blue")
        case .purple:
            return L("tagColor.purple")
        case .pink:
            return L("tagColor.pink")
        case .red:
            return L("tagColor.red")
        case .orange:
            return L("tagColor.orange")
        case .yellow:
            return L("tagColor.yellow")
        case .green:
            return L("tagColor.green")
        case .graphite:
            return L("tagColor.gray")
        }
    }

    /// Risolve il colore dato il raw salvato e l'eventuale hex personalizzato.
    static func color(forRaw raw: String, customHex: String) -> Color {
        if raw == customRaw, let custom = Color(hexString: customHex) {
            return custom
        }
        return (AppAccentColor(rawValue: raw) ?? .blue).color
    }

    /// Legge il colore corrente da UserDefaults (per contesti senza @AppStorage).
    static var current: Color {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppAccentColor.blue.rawValue
        let hex = UserDefaults.standard.string(forKey: customHexKey) ?? ""
        return color(forRaw: raw, customHex: hex)
    }
}

extension Color {
    /// Inizializza da una stringa esadecimale "#RRGGBB" (o "RRGGBB").
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }

    /// Rappresentazione esadecimale "#RRGGBB" in spazio colore sRGB.
    var hexString: String {
        let ns = (NSColor(self).usingColorSpace(.sRGB)) ?? NSColor.systemBlue
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct SidebarView: View {
    /// Quando valorizzato questa istanza viene installata come radice della finestra AppKit di
    /// configurazione. In questo modo tutti i DynamicProperty di SwiftUI sono realmente attivi
    /// anche nella finestra separata (azioni, Task, @State e @ObservedObject).
    var settingsOnlyDismiss: (() -> Void)?
    let selectedFolderURL: URL?
    let recentFolderURLs: [URL]
    let managedFolderURLs: [URL]
    let treeRootURL: URL?
    @Binding var sidebarFontSize: Double
    @Binding var contentFontSize: Double
    @Binding var appearanceMode: String
    @Binding var showHiddenFiles: Bool
    @Binding var showFileExtensions: Bool
    /// Icona nella barra dei menu: letta/scritta direttamente qui (stessa chiave usata da
    /// `FolderBaseApp` per inserire/rimuovere la `MenuBarExtra`).
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    /// Avvio automatico al login del Mac (gestito via SMAppService).
    @ObservedObject private var launchAtLogin = LaunchAtLoginService.shared
    let selectFolder: (URL) -> Void
    let removeFolder: (URL) -> Void
    let reorderFolder: (URL, Int) -> Void
    let chooseFolder: () -> Void
    let navigateTo: (URL) -> Void
    let moveItems: ([String], URL) -> Void
    let directoryAction: (URL, DirectoryTreeAction) -> Void
    @ObservedObject var templateStore: TemplateStore
    @ObservedObject var metadataStore: MetadataStore
    @ObservedObject var backupService: BackupService
    @ObservedObject var indexingService: IndexingService
    /// NON osservato dalla sidebar: gli alberi (`DirectoryTreeView`) lo osservano già
    /// direttamente e si aggiornano da soli. Osservarlo qui faceva rivalutare l'intera sidebar
    /// (albero incluso) a ogni evento FSEvents.
    let directoryCache: DirectorySnapshotCache
    let chatService: ChatService
    /// Item selezionato nella tabella: ne mostriamo la nota nel pannello in fondo alla sidebar.
    let selectedNoteItem: FileItem?
    @ObservedObject private var loc = LocalizationManager.shared

    init(
        selectedFolderURL: URL?, recentFolderURLs: [URL], managedFolderURLs: [URL], treeRootURL: URL?,
        sidebarFontSize: Binding<Double>, contentFontSize: Binding<Double>,
        appearanceMode: Binding<String>, showHiddenFiles: Binding<Bool>, showFileExtensions: Binding<Bool>,
        selectFolder: @escaping (URL) -> Void, removeFolder: @escaping (URL) -> Void,
        reorderFolder: @escaping (URL, Int) -> Void, chooseFolder: @escaping () -> Void,
        navigateTo: @escaping (URL) -> Void, moveItems: @escaping ([String], URL) -> Void,
        directoryAction: @escaping (URL, DirectoryTreeAction) -> Void,
        templateStore: TemplateStore, metadataStore: MetadataStore, backupService: BackupService,
        indexingService: IndexingService, directoryCache: DirectorySnapshotCache,
        chatService: ChatService, selectedNoteItem: FileItem?,
        settingsOnlyDismiss: (() -> Void)? = nil
    ) {
        self.settingsOnlyDismiss = settingsOnlyDismiss
        self.selectedFolderURL = selectedFolderURL
        self.recentFolderURLs = recentFolderURLs
        self.managedFolderURLs = managedFolderURLs
        self.treeRootURL = treeRootURL
        self._sidebarFontSize = sidebarFontSize
        self._contentFontSize = contentFontSize
        self._appearanceMode = appearanceMode
        self._showHiddenFiles = showHiddenFiles
        self._showFileExtensions = showFileExtensions
        self.selectFolder = selectFolder
        self.removeFolder = removeFolder
        self.reorderFolder = reorderFolder
        self.chooseFolder = chooseFolder
        self.navigateTo = navigateTo
        self.moveItems = moveItems
        self.directoryAction = directoryAction
        self._templateStore = ObservedObject(wrappedValue: templateStore)
        self._metadataStore = ObservedObject(wrappedValue: metadataStore)
        self._backupService = ObservedObject(wrappedValue: backupService)
        self._indexingService = ObservedObject(wrappedValue: indexingService)
        self.directoryCache = directoryCache
        self.chatService = chatService
        self.selectedNoteItem = selectedNoteItem
    }

    @State private var isAddingTemplate = false
    @State private var templatePendingEdit: MetadataTemplate?
    @State private var maintenanceMessage: String?
    @State private var maintenanceOrphans = 0
    /// Identità degli orfani trovati dall'ultima riconciliazione: il purge le riusa
    /// senza dover ri-risolvere tutti i file gestiti.
    @State private var maintenanceOrphanIdentities: [String] = []
    @State private var isReconciling = false
    @State private var isCleaningIndexes = false
    @AppStorage("autoPurgeOrphans") private var autoPurgeOrphans = false
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = false
    @State private var updateState: UpdateUIState = .idle
    @State private var backupMessage: String?
    @State private var backupFailed = false
    @State private var isConfirmingRestore = false
    @State private var pendingRestoreURL: URL?
    @State private var folderIndexStatuses: [String: FolderIndexSnapshot] = [:]
    @State private var indexingRootPath: String?
    @State private var exclusionRootPath = ""
    /// Interruttore generale dell'AI: quando è false l'indicizzazione, la chat e la ricerca per
    /// contenuto sono disattivate e le relative icone spariscono dall'interfaccia.
    @AppStorage(AIProviderSettings.Keys.enabled) private var aiEnabled = true
    @AppStorage(AIProviderSettings.Keys.provider) private var aiProviderRaw = AIEmbeddingProvider.apple.rawValue
    @AppStorage(AIProviderSettings.Keys.ollamaBaseURL) private var aiOllamaBaseURL = AIProviderSettings.defaultOllamaBaseURL
    @AppStorage(AIProviderSettings.Keys.ollamaModel) private var aiOllamaModel = AIProviderSettings.defaultOllamaModel
    @AppStorage(AIProviderSettings.Keys.openAIModel) private var aiOpenAIModel = AIProviderSettings.defaultOpenAIModel
    @State private var openAIKeyInput = ""
    @AppStorage(AIProviderSettings.Keys.hasOpenAIKey) private var hasOpenAIKey = false
    @State private var aiTesting = false
    @State private var aiTestMessage: String?
    @AppStorage(AIProviderSettings.Keys.chatProvider) private var aiChatProviderRaw = AIChatProvider.none.rawValue
    @AppStorage(AIProviderSettings.Keys.ollamaChatModel) private var aiOllamaChatModel = AIProviderSettings.defaultOllamaChatModel
    @AppStorage(AIProviderSettings.Keys.openAIChatModel) private var aiOpenAIChatModel = AIProviderSettings.defaultOpenAIChatModel
    @AppStorage(AIProviderSettings.Keys.chatContextChunks) private var aiChatContextChunks = AIProviderSettings.defaultChatContextChunks
    @AppStorage(AIProviderSettings.Keys.excludedSourcePaths) private var aiExcludedSourcePathsData = Data()
    @State private var chatTesting = false
    @State private var chatTestMessage: String?
    @State private var aiExclusionSuggestions: [AIExclusionSuggestion] = []
    @State private var aiExclusionScanning = false
    @State private var aiExclusionScanToken = UUID()
    /// Altezza del pannello note in fondo alla sidebar, regolabile dall'utente e persistita.
    @AppStorage(AppAccentColor.storageKey) private var appAccentRaw = AppAccentColor.blue.rawValue
    @AppStorage(AppAccentColor.customHexKey) private var appAccentCustomHex = ""
    /// Copia locale del colore personalizzato: il ColorPicker vi scrive in modo continuo (senza
    /// il round-trip su hex che causava lo "scatto" del selettore).
    @State private var customAccentDraft = Color.blue
    /// Colore d'accento corrente (barre di selezione, evidenziazioni).
    private var accent: Color { AppAccentColor.color(forRaw: appAccentRaw, customHex: appAccentCustomHex) }
    @AppStorage("notesPanelHeight") private var notesPanelHeight = 160.0
    /// Altezza di partenza catturata all'inizio del trascinamento dell'handle di resize.
    @State private var notesDragBaseline: Double?

    @ViewBuilder
    var body: some View {
        if let settingsOnlyDismiss {
            settingsWindow(dismiss: settingsOnlyDismiss)
        } else {
            sidebarContent
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Albero e cartelle in uno ScrollView (NON una List): evita i glitch di
            // layout/transizione del NavigationSplitView durante avanti/indietro.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if recentFolderURLs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            sectionHeader(L("sidebar.structure"))
                            Label(L("common.noFolders"), systemImage: "folder")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            sectionHeader(L("sidebar.structure"))

                            // Albero isolato in un subview Equatable: gli altri publish della
                            // sidebar (progresso indicizzazione, backup, metadati) NON ne forzano
                            // più la ricostruzione. Gli alberi restano reattivi ai propri eventi
                            // (directoryCache) tramite le loro sottoscrizioni interne.
                            SidebarTreeSection(
                                rootURLs: recentFolderURLs,
                                selectedFolderURL: selectedFolderURL,
                                fontSize: sidebarFontSize,
                                treeRootURL: treeRootURL,
                                onSelect: navigateTo,
                                onMoveItems: moveItems,
                                onRemoveRoot: removeFolder,
                                onAction: directoryAction,
                                metadataStore: metadataStore,
                                chatService: chatService,
                                directoryCache: directoryCache
                            )
                            .equatable()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            // Il pannello dettagli appare solo se nella cartella è stato configurato almeno un
            // campo. Senza campi non viene mostrato.
            if selectedFolderURL != nil, !allFields.isEmpty {
                notesPanel
            }

            Divider()

            Button {
                SettingsWindowPresenter.show { dismiss in
                    AnyView(SidebarView(
                        selectedFolderURL: selectedFolderURL,
                        recentFolderURLs: recentFolderURLs,
                        managedFolderURLs: managedFolderURLs,
                        treeRootURL: treeRootURL,
                        sidebarFontSize: $sidebarFontSize,
                        contentFontSize: $contentFontSize,
                        appearanceMode: $appearanceMode,
                        showHiddenFiles: $showHiddenFiles,
                        showFileExtensions: $showFileExtensions,
                        selectFolder: selectFolder,
                        removeFolder: removeFolder,
                        reorderFolder: reorderFolder,
                        chooseFolder: chooseFolder,
                        navigateTo: navigateTo,
                        moveItems: moveItems,
                        directoryAction: directoryAction,
                        templateStore: templateStore,
                        metadataStore: metadataStore,
                        backupService: backupService,
                        indexingService: indexingService,
                        directoryCache: directoryCache,
                        chatService: chatService,
                        selectedNoteItem: selectedNoteItem,
                        settingsOnlyDismiss: dismiss
                    ))
                }
            } label: {
                Label(L("sidebar.configuration"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .padding(12)
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

    // MARK: - Pannello Note (in fondo alla sidebar, sotto l'albero)

    /// Mostra ed EDITA tutti i campi metadata configurati per l'item selezionato nella tabella:
    /// prima gli altri campi (numero, data, select/kanban, link), poi le note libere. Le modifiche
    /// scrivono nel metadataStore, quindi aggiornano anche la cella corrispondente nella tabella.
    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            resizeHandle

            if let selectedNoteItem {
                HStack(spacing: 6) {
                    Image(nsImage: FileIconProvider.icon(for: selectedNoteItem))
                        .resizable()
                        .frame(width: sidebarFontSize + 3, height: sidebarFontSize + 3)
                    Text(displayName(for: selectedNoteItem))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: sidebarFontSize))
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(accent.opacity(0.15))
                )
                .padding(.horizontal, 4)
            }

            notesBody
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .frame(height: notesPanelHeight)
    }

    /// Handle in cima al pannello: trascinandolo su/giù se ne regola l'altezza.
    private var resizeHandle: some View {
        ZStack {
            Divider()
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 28, height: 4)
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let baseline = notesDragBaseline ?? notesPanelHeight
                    if notesDragBaseline == nil { notesDragBaseline = baseline }
                    // Trascinando verso l'alto (translation negativa) il pannello si ingrandisce.
                    let proposed = baseline - Double(value.translation.height)
                    notesPanelHeight = min(max(proposed, 90), 520)
                }
                .onEnded { _ in notesDragBaseline = nil }
        )
    }

    @ViewBuilder
    private var notesBody: some View {
        if let selectedNoteItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Gli altri campi (numero, data, select/kanban, link) sono affiancati in un
                    // layout a flusso, ciascuno con la larghezza adatta al proprio dato.
                    if !otherFields.isEmpty {
                        FlowLayout(spacing: 12, lineSpacing: 10) {
                            ForEach(otherFields) { field in
                                fieldCell(field, item: selectedNoteItem)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Le note libere occupano tutta la larghezza, una sotto l'altra.
                    ForEach(noteFields) { field in
                        fieldCell(field, item: selectedNoteItem)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity)
        } else {
            Text(L("notes.noSelection"))
                .font(.system(size: sidebarFontSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 4)
        }
    }

    /// Una cella dell'inspector: etichetta (ingrandita) del campo + editor adatto al tipo,
    /// con larghezza proporzionata al dato (le note libere si estendono a tutta la larghezza).
    @ViewBuilder
    private func fieldCell(_ field: MetadataField, item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Stesso stile dell'intestazione "STRUTTURA" sopra l'albero.
            Text(field.name.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            fieldEditor(field, item: item)
        }
        .modifier(FieldWidth(width: fieldWidth(for: field.kind)))
    }

    /// Larghezza consigliata per tipo di campo (nil = tutta la larghezza disponibile).
    private func fieldWidth(for kind: MetadataFieldKind) -> CGFloat? {
        switch kind {
        case .number:
            return 96
        case .date:
            return 150
        case .select, .kanban:
            return 150
        case .link:
            return 240
        case .text:
            return nil
        }
    }

    /// Editor specifico per il tipo di campo. Le modifiche scrivono nel metadataStore.
    @ViewBuilder
    private func fieldEditor(_ field: MetadataField, item: FileItem) -> some View {
        let identityKey = "\(item.identity)#\(field.id)"
        switch field.kind {
        case .text:
            NoteFieldEditor(
                fontSize: sidebarFontSize,
                identityKey: identityKey,
                initialValue: metadataStore.value(for: item, field: field),
                onChange: { metadataStore.update(item: item, field: field, value: $0) }
            )
        case .number:
            SidebarLineEditor(
                fontSize: sidebarFontSize,
                identityKey: identityKey,
                initialValue: metadataStore.value(for: item, field: field),
                onChange: { metadataStore.update(item: item, field: field, value: $0) }
            )
        case .link:
            SidebarLineEditor(
                fontSize: sidebarFontSize,
                identityKey: identityKey,
                initialValue: metadataStore.value(for: item, field: field),
                placeholder: L("link.placeholder"),
                showsOpenButton: true,
                onChange: { metadataStore.update(item: item, field: field, value: $0) }
            )
        case .date:
            SidebarDateEditor(value: fieldBinding(for: field, item: item))
        case .select, .kanban:
            SidebarSelectEditor(field: field, value: fieldBinding(for: field, item: item))
        }
    }

    /// Binding diretto sul valore del campo (usato per editor a modifica discreta: data, select).
    private func fieldBinding(for field: MetadataField, item: FileItem) -> Binding<String> {
        Binding(
            get: { metadataStore.value(for: item, field: field) },
            set: { metadataStore.update(item: item, field: field, value: $0) }
        )
    }

    /// Nome mostrato nell'intestazione: senza l'estensione del file (le cartelle restano intatte).
    private func displayName(for item: FileItem) -> String {
        guard !item.isFolder else { return item.name }
        let withoutExt = (item.name as NSString).deletingPathExtension
        return withoutExt.isEmpty ? item.name : withoutExt
    }

    /// Tutti i campi configurati per la cartella corrente.
    private var allFields: [MetadataField] {
        metadataStore.fields(for: selectedFolderURL, configurationRootURL: treeRootURL)
    }

    /// Campi di tipo testo ("Nota libera") della cartella corrente.
    private var noteFields: [MetadataField] {
        allFields.filter { $0.kind == .text }
    }

    /// Campi diversi dalla nota libera (mostrati sopra le note).
    private var otherFields: [MetadataField] {
        allFields.filter { $0.kind != .text }
    }

    // MARK: - Finestra Configurazione (sidebar + dettaglio, stile Impostazioni di sistema)

    private func settingsWindow(dismiss: @escaping () -> Void) -> some View {
        SettingsWindowContainer(accent: accent, dismiss: dismiss) { section in
            AnyView(settingsDetail(section: section, dismiss: dismiss))
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
                if templateStore.activeTemplateID == updated.id {
                    propagateTemplateUpdate(from: template, to: updated)
                }
                templateStore.update(updated)
                templatePendingEdit = nil
            } cancel: {
                templatePendingEdit = nil
            }
        }
    }

    private func settingsDetail(section: SettingsSection, dismiss: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.title2)
                    .foregroundStyle(accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(section.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L("common.done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                Group {
                    switch section {
                    case .folders:
                        foldersSettings
                    case .appearance:
                        appearanceSettings
                    case .display:
                        displaySettings
                    case .startup:
                        startupSettings
                    case .language:
                        languageSettings
                    case .templates:
                        templatesSettings
                    case .contentIndexing:
                        contentIndexingSettings
                    case .indexing:
                        indexingSettings
                    case .maintenance:
                        maintenanceSettings
                    case .backup:
                        backupSettings
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
                VStack(alignment: .leading, spacing: 8) {
                    if recentFolderURLs.isEmpty {
                        Label(L("common.noFolders"), systemImage: "folder")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(recentFolderURLs.enumerated()), id: \.element.path) { index, folderURL in
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
                                    reorderFolder(folderURL, -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)

                                Button {
                                    reorderFolder(folderURL, 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == recentFolderURLs.count - 1)

                                Button {
                                    removeFolder(folderURL)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
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

    private var indexingSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L("ai.enabled"), isOn: $aiEnabled)
                        .font(.headline)
                    Text(L("ai.enabledNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("ai.enabled.card"), systemImage: "sparkles")
            }

            if aiEnabled {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("ai.engine.intro"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(L("ai.provider.label"), selection: $aiProviderRaw) {
                        Text(L("ai.provider.apple")).tag(AIEmbeddingProvider.apple.rawValue)
                        Text(L("ai.provider.ollama")).tag(AIEmbeddingProvider.ollama.rawValue)
                        Text(L("ai.provider.openai")).tag(AIEmbeddingProvider.openai.rawValue)
                    }
                    .pickerStyle(.radioGroup)

                    if aiProviderRaw == AIEmbeddingProvider.ollama.rawValue {
                        TextField(L("ai.ollama.url"), text: $aiOllamaBaseURL)
                            .textFieldStyle(.roundedBorder)
                        TextField(L("ai.ollama.model"), text: $aiOllamaModel)
                            .textFieldStyle(.roundedBorder)
                    } else if aiProviderRaw == AIEmbeddingProvider.openai.rawValue {
                        TextField(L("ai.openai.model"), text: $aiOpenAIModel)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            SecureField(L("ai.openai.key"), text: $openAIKeyInput)
                                .textFieldStyle(.roundedBorder)
                            Button(L("ai.openai.saveKey")) { saveOpenAIKey() }
                                .disabled(openAIKeyInput.isEmpty)
                        }
                        if hasOpenAIKey {
                            HStack(spacing: 8) {
                                Label(L("ai.openai.keySet"), systemImage: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Button(L("ai.openai.removeKey")) {
                                    KeychainStore.delete(account: AIProviderSettings.openAIKeyAccount)
                                    hasOpenAIKey = false
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }
                        Text(L("ai.cloudWarning"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 12) {
                        Button {
                            testEngine()
                        } label: {
                            Label(L("ai.test"), systemImage: "bolt.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(aiTesting)

                        if aiTesting {
                            ProgressView().controlSize(.small)
                        }
                        if let aiTestMessage {
                            Text(aiTestMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(L("ai.reindexNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("ai.engine.card"), systemImage: "cpu")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("ai.chat.intro"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(L("ai.chat.provider"), selection: $aiChatProviderRaw) {
                        Text(L("ai.chat.none")).tag(AIChatProvider.none.rawValue)
                        Text(L("ai.provider.ollama")).tag(AIChatProvider.ollama.rawValue)
                        Text(L("ai.provider.openai")).tag(AIChatProvider.openai.rawValue)
                    }
                    .pickerStyle(.radioGroup)

                    if aiChatProviderRaw == AIChatProvider.ollama.rawValue {
                        TextField(L("ai.chat.model"), text: $aiOllamaChatModel)
                            .textFieldStyle(.roundedBorder)
                        Text(L("ai.chat.ollamaNote"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if aiChatProviderRaw == AIChatProvider.openai.rawValue {
                        TextField(L("ai.chat.model"), text: $aiOpenAIChatModel)
                            .textFieldStyle(.roundedBorder)
                        Text(L("ai.chat.openaiNote"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if aiChatProviderRaw != AIChatProvider.none.rawValue {
                        HStack(spacing: 12) {
                            Button {
                                testChat()
                            } label: {
                                Label(L("ai.chat.test"), systemImage: "bolt.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(chatTesting)

                            if chatTesting {
                                ProgressView().controlSize(.small)
                            }
                            if let chatTestMessage {
                                Text(chatTestMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Divider()

                        Stepper(value: $aiChatContextChunks, in: 1...40) {
                            Text("\(L("ai.chat.sources")): \(aiChatContextChunks)")
                        }
                        Text(L("ai.chat.sourcesNote"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("ai.chat.card"), systemImage: "bubble.left.and.bubble.right")
            }

            } // if aiEnabled
        }
        .onChange(of: aiProviderRaw) { _, _ in
            aiTestMessage = nil
            // Lo stato dipende dal motore: al cambio provider lo si ricalcola.
            Task { for root in indexRootURLs { await recomputeStatus(for: root) } }
        }
        .onChange(of: aiChatProviderRaw) { _, _ in
            chatTestMessage = nil
        }
    }

    private var contentIndexingSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("indexing.intro"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    if indexRootURLs.isEmpty {
                        Label(L("common.noFolders"), systemImage: "folder")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(indexRootURLs, id: \.path) { folderURL in
                            indexFolderRow(folderURL)
                            aiExclusionsSettings(for: folderURL)
                            if folderURL.path != indexRootURLs.last?.path { Divider() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("indexing.folders.card"), systemImage: "doc.text.magnifyingglass")
            }

            if !indexingService.isIndexing, indexingService.embeddingFailures > 0 {
                Label("\(L("indexing.embedFailures")) \(indexingService.embeddingFailures) file. \(failedFilesPreview)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .task(id: indexRootURLs.map(\.path).joined(separator: "|")) { loadAllCachedStatuses() }
        .onAppear {
            if exclusionRootPath.isEmpty { exclusionRootPath = indexRootURLs.first?.path ?? "" }
        }
        .onChange(of: exclusionRootPath) { _, _ in aiExclusionSuggestions = [] }
        .onChange(of: indexingService.isIndexing) { _, running in
            guard !running, let rootPath = indexingRootPath,
                  let root = indexRootURLs.first(where: { $0.path == rootPath }) else { return }
            Task {
                await recomputeStatus(for: root)
                indexingRootPath = nil
            }
        }
    }

    private func aiExclusionsSettings(for root: URL) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("ai.exclusions.perFolderIntro"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button { chooseAIExclusions(for: root, directories: false) } label: {
                        Label(L("ai.exclusions.addFiles"), systemImage: "doc.badge.plus")
                    }
                    Button { chooseAIExclusions(for: root, directories: true) } label: {
                        Label(L("ai.exclusions.addFolders"), systemImage: "folder.badge.plus")
                    }
                }

                if exclusions(for: root).isEmpty {
                    Text(L("ai.exclusions.emptyForFolder")).font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(exclusions(for: root), id: \.self) { path in
                            aiExclusionRow(path: path, root: root)
                            if path != exclusions(for: root).last { Divider() }
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }

                Divider()
                HStack(spacing: 10) {
                    Button { analyzeAIExclusionSuggestions(for: root) } label: {
                        Label(L("ai.exclusions.analyze"), systemImage: "wand.and.stars")
                    }
                    .disabled(aiExclusionScanning)
                    if aiExclusionScanning, exclusionRootPath == root.path { ProgressView().controlSize(.small) }
                    Spacer()
                    if exclusionRootPath == root.path, !aiExclusionSuggestions.isEmpty {
                        Button(L("ai.exclusions.addAllSuggestions")) {
                            addAIExclusionPaths(aiExclusionSuggestions.map(\.path), for: root)
                        }.buttonStyle(.borderless)
                    }
                }
                Text(L("ai.exclusions.suggestionNote"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if exclusionRootPath == root.path, !aiExclusionSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(aiExclusionSuggestions) { suggestion in
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(URL(fileURLWithPath: suggestion.path).lastPathComponent).lineLimit(1)
                                    Text(suggestion.reason + " · " + suggestion.path)
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button(L("common.add")) { addAIExclusionPaths([suggestion.path], for: root) }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 7)
                            if suggestion.id != aiExclusionSuggestions.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            settingsCardLabel(L("ai.exclusions.card"), systemImage: "eye.slash")
        }
    }

    private func exclusions(for root: URL) -> [String] {
        aiExclusionsByRoot[root.standardizedFileURL.path] ?? []
    }

    private var indexRootURLs: [URL] {
        AIExclusionPolicy.topLevelRoots(managedFolderURLs)
    }

    @ViewBuilder
    private func indexFolderRow(_ folderURL: URL) -> some View {
        let snapshot = folderIndexStatuses[folderURL.path] ?? FolderIndexSnapshot()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(indexStatusColor(snapshot.status)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderURL.lastPathComponent).fontWeight(.medium)
                    Text(folderURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(indexStatusLabel(snapshot)).font(.callout).foregroundStyle(.secondary)
                if snapshot.isChecking {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { Task { await recomputeStatus(for: folderURL) } } label: {
                        Label(L("indexing.recheck"), systemImage: "arrow.clockwise")
                    }
                        .buttonStyle(.borderless)
                        .help(L("indexing.recheck"))
                        .disabled(indexingService.isIndexing)
                }
            }
            HStack(spacing: 10) {
                Button {
                    indexingRootPath = folderURL.path
                    indexingService.indexRecursively(root: folderURL, store: metadataStore)
                } label: {
                    Label(indexButtonTitle(snapshot.status), systemImage: "text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(indexingService.isIndexing)
                if indexingService.isIndexing, indexingRootPath == folderURL.path {
                    ProgressView().controlSize(.small)
                    Text(indexingProgressText).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    Button(L("index.stop")) { indexingService.cancel() }.buttonStyle(.bordered)
                }
                if let checkedAt = snapshot.checkedAt {
                    Spacer()
                    Text("\(L("indexing.checkedAt")) \(Self.statusDateFormatter.string(from: checkedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func saveOpenAIKey() {
        KeychainStore.save(openAIKeyInput, account: AIProviderSettings.openAIKeyAccount)
        hasOpenAIKey = !openAIKeyInput.isEmpty
        openAIKeyInput = ""
    }

    private var aiExclusionsByRoot: AIExclusionPolicy.ExclusionsByRoot {
        AIExclusionPolicy.decodeByRoot(aiExcludedSourcePathsData, knownRoots: indexRootURLs)
    }

    private func aiExclusionRow(path: String, root: URL) -> some View {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return HStack(spacing: 8) {
            Image(systemName: isDirectory.boolValue ? "folder.fill" : "doc.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .lineLimit(1)
                Text(exists ? path : "\(L("ai.exclusions.missing")) · \(path)")
                    .font(.caption2)
                    .foregroundStyle(exists ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                removeAIExclusionPath(path, for: root)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L("ai.exclusions.remove"))
        }
        .padding(.vertical, 7)
    }

    private func chooseAIExclusions(for root: URL, directories: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.canCreateDirectories = false
        panel.directoryURL = root
        panel.prompt = L("common.add")
        guard panel.runModal() == .OK else { return }
        let rootPrefix = root.path + "/"
        addAIExclusionPaths(panel.urls.map(\.standardizedFileURL.path).filter {
            $0 == root.path || $0.hasPrefix(rootPrefix)
        }, for: root)
    }

    private func addAIExclusionPaths(_ paths: [String], for root: URL) {
        var mapping = aiExclusionsByRoot
        let rootPath = root.standardizedFileURL.path
        mapping[rootPath] = (mapping[rootPath] ?? []) + paths
        aiExcludedSourcePathsData = AIExclusionPolicy.encode(mapping)
        let excluded = Set(mapping[rootPath] ?? [])
        aiExclusionSuggestions.removeAll { excluded.contains($0.path) }
        Task { await recomputeStatus(for: root) }
    }

    private func removeAIExclusionPath(_ path: String, for root: URL) {
        var mapping = aiExclusionsByRoot
        let rootPath = root.standardizedFileURL.path
        mapping[rootPath] = (mapping[rootPath] ?? []).filter { $0 != path }
        aiExcludedSourcePathsData = AIExclusionPolicy.encode(mapping)
        Task { await recomputeStatus(for: root) }
    }

    private func analyzeAIExclusionSuggestions(for root: URL) {
        let excluded = exclusions(for: root)
        let token = UUID()
        exclusionRootPath = root.path
        aiExclusionScanToken = token
        aiExclusionScanning = true
        aiExclusionSuggestions = []
        Task {
            let suggestions = await Task.detached(priority: .utility) {
                AIExclusionPolicy.suggestions(under: [root], excluding: excluded)
            }.value
            guard aiExclusionScanToken == token else { return }
            aiExclusionSuggestions = suggestions
            aiExclusionScanning = false
        }
    }

    private func testEngine() {
        aiTesting = true
        aiTestMessage = nil
        Task {
            let embedder = EmbeddingEngine.active()
            let result = await embedder.embed("prova di connessione al motore di embedding")
            aiTesting = false
            if let result {
                aiTestMessage = "\(L("ai.test.ok")) \(result.vector.count)"
            } else {
                aiTestMessage = L("ai.test.fail")
            }
        }
    }

    private func testChat() {
        chatTesting = true
        chatTestMessage = nil
        Task {
            guard let chat = ChatEngine.active() else {
                chatTesting = false
                chatTestMessage = L("chat.needProvider")
                return
            }
            var reply = ""
            do {
                for try await token in chat.stream(system: "Rispondi con una sola parola.", turns: [ChatTurn(role: "user", content: "Scrivi: OK")]) {
                    reply += token
                    if reply.count > 40 { break }
                }
            } catch {
                chatTesting = false
                chatTestMessage = L("ai.chat.testFail")
                return
            }
            chatTesting = false
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            chatTestMessage = trimmed.isEmpty
                ? L("ai.chat.testFail")
                : "\(L("ai.chat.testOk")) \"\(String(trimmed.prefix(40)))\""
        }
    }

    /// Legge lo stato MEMORIZZATO (istantaneo, nessuna enumerazione): usato all'apertura.
    private func loadAllCachedStatuses() {
        for root in indexRootURLs {
            if let cached = indexingService.loadStatus(root: root, store: metadataStore) {
                folderIndexStatuses[root.path] = FolderIndexSnapshot(status: cached.status, checkedAt: cached.checkedAt)
            } else {
                folderIndexStatuses[root.path] = FolderIndexSnapshot()
            }
        }
    }

    /// Ricalcola lo stato enumerando il sottoalbero e lo memorizza (su richiesta / a fine indicizzazione).
    private func recomputeStatus(for root: URL) async {
        var snapshot = folderIndexStatuses[root.path] ?? FolderIndexSnapshot()
        snapshot.isChecking = true
        folderIndexStatuses[root.path] = snapshot
        let status = await indexingService.recomputeStatus(root: root, store: metadataStore)
        folderIndexStatuses[root.path] = FolderIndexSnapshot(status: status, checkedAt: Date())
    }

    private static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func indexStatusColor(_ status: FolderIndexStatus) -> Color {
        switch status {
        case .upToDate:
            return .green
        case .stale:
            return .orange
        case .notIndexed, .unknown:
            return .gray
        }
    }

    private func indexStatusLabel(_ snapshot: FolderIndexSnapshot) -> String {
        if snapshot.isChecking { return L("indexing.status.checking") }
        switch snapshot.status {
        case .unknown:
            return L("indexing.status.unknown")
        case .notIndexed:
            return L("indexing.status.notIndexed")
        case let .upToDate(files):
            return "\(L("indexing.status.upToDate")) · \(files) file"
        case let .stale(indexed, total):
            return "\(L("indexing.status.stale")) · \(indexed)/\(total)"
        }
    }

    private func indexButtonTitle(_ status: FolderIndexStatus) -> String {
        if case .notIndexed = status { return L("indexing.button") }
        if case .unknown = status { return L("indexing.button") }
        return L("indexing.reindex")
    }

    private var indexingProgressText: String {
        guard let progress = indexingService.progress else { return "" }
        if progress.total == 0 { return L("indexing.scanning") }
        return "\(progress.processed)/\(progress.total)"
    }

    /// Anteprima dei file con embedding fallito: i primi nomi, più "e altri N" se sono di più.
    private var failedFilesPreview: String {
        let names = indexingService.embeddingFailedFiles
        let shown = names.prefix(5).joined(separator: ", ")
        let hidden = indexingService.embeddingFailures - min(names.count, 5)
        guard hidden > 0 else { return shown }
        return "\(shown) \(L("indexing.embedFailures.andMore")) \(hidden)"
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
                            isReconciling = true
                            metadataStore.reconcileManagedFiles { relocated, missingIdentities in
                                isReconciling = false
                                maintenanceOrphans = missingIdentities.count
                                maintenanceOrphanIdentities = missingIdentities
                                maintenanceMessage = "\(L("maint.updated")) \(relocated) · \(L("maint.orphans")) \(missingIdentities.count)"
                            }
                        } label: {
                            Label(L("maint.repair"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isReconciling)

                        if isReconciling {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if maintenanceOrphans > 0 {
                            Button(role: .destructive) {
                                let removed = metadataStore.purge(identities: maintenanceOrphanIdentities)
                                maintenanceOrphans = 0
                                maintenanceOrphanIdentities = []
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
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("maint.indexCleanupNote"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(role: .destructive) {
                            isCleaningIndexes = true
                            maintenanceMessage = nil
                            Task {
                                let result = await metadataStore.purgeOrphanedIndexes(currentRoots: indexRootURLs)
                                isCleaningIndexes = false
                                folderIndexStatuses = folderIndexStatuses.filter { snapshot in
                                    indexRootURLs.contains { $0.path == snapshot.key }
                                }
                                maintenanceMessage = "\(L("maint.indexCleanupDone")) \(result.indexRecordsRemoved) · \(L("maint.indexedFilesRemoved")) \(result.indexedFilesRemoved + result.legacyIndexedFilesRemoved)"
                            }
                        } label: {
                            Label(L("maint.indexCleanup"), systemImage: "externaldrive.badge.xmark")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isCleaningIndexes || indexingService.isIndexing)

                        if isCleaningIndexes { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("maint.indexCleanupCard"), systemImage: "externaldrive.badge.xmark")
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

    private var backupSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("backup.intro"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Backup su richiesta
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("backup.destinationLabel"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if backupService.destinationPath.isEmpty {
                            Label(L("backup.noDestination"), systemImage: "folder.badge.questionmark")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(backupService.destinationPath)
                                .font(.callout)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            chooseBackupFolder()
                        } label: {
                            Label(L("backup.chooseFolder"), systemImage: "folder")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            runManualBackup()
                        } label: {
                            Label(L("backup.runNow"), systemImage: "externaldrive.badge.timemachine")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(backupService.destinationPath.isEmpty)
                    }

                    Text(L("backup.contentsNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(L("backup.lastPrefix")) \(lastBackupText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let automaticError = backupService.lastBackupError {
                        Text("\(L("backup.errorPrefix")) \(automaticError)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let backupMessage {
                        Text(backupMessage)
                            .font(.callout)
                            .foregroundStyle(backupFailed ? .red : .green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("backup.manualCard"), systemImage: "externaldrive")
            }

            // Backup automatico
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("backup.autoToggle"), isOn: $backupService.autoEnabled)
                        .toggleStyle(.checkbox)

                    HStack(spacing: 6) {
                        Text(L("backup.intervalLabel"))
                        Stepper(value: $backupService.intervalHours, in: 1...168) {
                            Text("\(backupService.intervalHours) \(L("backup.hoursSuffix"))")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                    .disabled(!backupService.autoEnabled)

                    HStack(spacing: 6) {
                        Text(L("backup.keepLabel"))
                        Stepper(value: $backupService.keepCount, in: 1...100) {
                            Text("\(backupService.keepCount)")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                    .disabled(!backupService.autoEnabled)

                    Text(L("backup.autoNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("backup.autoCard"), systemImage: "clock.arrow.circlepath")
            }

            // Ripristino
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("backup.restoreIntro"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        chooseRestoreFile()
                    } label: {
                        Label(L("backup.restoreButton"), systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("backup.restoreCard"), systemImage: "arrow.uturn.backward")
            }
        }
        .alert(L("backup.restore.confirmTitle"), isPresented: $isConfirmingRestore, presenting: pendingRestoreURL) { _ in
            Button(L("backup.restore.confirmButton"), role: .destructive) {
                if let url = pendingRestoreURL { performRestore(from: url) }
                pendingRestoreURL = nil
            }
            Button(L("common.cancel"), role: .cancel) {
                pendingRestoreURL = nil
            }
        } message: { _ in
            Text(L("backup.restore.confirmMessage"))
        }
    }

    private var lastBackupText: String {
        guard let date = backupService.lastBackupDate else { return L("backup.never") }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("backup.panel.chooseFolderPrompt")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupService.destinationPath = url.path
        backupMessage = nil
    }

    private func runManualBackup() {
        Task {
            do {
                let url = try await backupService.runBackup(auto: false)
                backupFailed = false
                backupMessage = "\(L("backup.donePrefix")) \(url.lastPathComponent)"
            } catch {
                backupFailed = true
                backupMessage = "\(L("backup.errorPrefix")) \(error.localizedDescription)"
            }
        }
    }

    private func chooseRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "sqlite") ?? .data]
        panel.prompt = L("backup.panel.restorePrompt")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
        isConfirmingRestore = true
    }

    private func performRestore(from url: URL) {
        Task {
            do {
                try await backupService.restore(from: url)
                backupFailed = false
                backupMessage = L("backup.restore.done")
            } catch {
                backupFailed = true
                backupMessage = "\(L("backup.errorPrefix")) \(error.localizedDescription)"
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(AppAccentColor.allCases) { option in
                            let isSelected = appAccentRaw == option.rawValue
                            Circle()
                                .fill(option.color)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .opacity(isSelected ? 1 : 0)
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                                        .padding(-3)
                                )
                                .contentShape(Circle())
                                .onTapGesture { appAccentRaw = option.rawValue }
                        }
                        Spacer(minLength: 0)
                    }

                    // Colore personalizzato: il ColorPicker scrive nella copia locale (fluida) e
                    // persiste l'hex; il valore letto è sempre quello locale, quindi niente scatti.
                    HStack(spacing: 10) {
                        let isCustom = appAccentRaw == AppAccentColor.customRaw
                        ColorPicker(selection: Binding(
                            get: { customAccentDraft },
                            set: { newColor in
                                customAccentDraft = newColor
                                appAccentCustomHex = newColor.hexString
                                appAccentRaw = AppAccentColor.customRaw
                            }
                        ), supportsOpacity: false) {
                            Text(L("appearance.accentCustom"))
                        }

                        if isCustom {
                            Label(L("appearance.accentCustomActive"), systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(accent)
                        }

                        Spacer(minLength: 0)
                    }

                    Text(L("appearance.accentNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onAppear {
                    // Allinea la copia locale al colore salvato senza innescare la set del picker.
                    customAccentDraft = Color(hexString: appAccentCustomHex) ?? accent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("appearance.accentCard"), systemImage: "paintpalette")
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

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L("display.showHidden"), isOn: $showHiddenFiles)
                        Text(L("display.showHiddenNote"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L("display.showExtensions"), isOn: $showFileExtensions)
                        Text(L("display.showExtensionsNote"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L("display.menuBarIcon"), isOn: $showMenuBarIcon)
                        Text(L("display.menuBarIconNote"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("display.card"), systemImage: "eye")
            }
        }
    }

    private var startupSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L("display.launchAtLogin"), isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                    Text(L("display.launchAtLoginNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .onAppear { launchAtLogin.refresh() }
            } label: {
                settingsCardLabel(L("startup.card"), systemImage: "power")
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
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L("templates.active"), selection: Binding(
                        get: { templateStore.activeTemplateID },
                        set: { newValue in
                            templateStore.activeTemplateID = newValue
                            applyActiveTemplateToAllRoots()
                        }
                    )) {
                        Text(L("templates.noneActive")).tag(String?.none)
                        ForEach(templateStore.templates) { template in
                            Text(template.name).tag(Optional(template.id))
                        }
                    }
                    .pickerStyle(.menu)

                    Text(L("templates.activeNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("templates.globalCard"), systemImage: "square.stack.3d.up.fill")
            }

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
                                    .foregroundStyle(accent)
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

                                Button {
                                    templateStore.delete(id: template.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
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

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("templates.cleanupNote"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(action: cleanMetadataDatabase) {
                            Label(L("templates.cleanup"), systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isReconciling)
                        if isReconciling { ProgressView().controlSize(.small) }
                        if let maintenanceMessage {
                            Text(maintenanceMessage).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("templates.cleanupCard"), systemImage: "cylinder.split.1x2")
            }
        }
    }

    private func applyActiveTemplateToAllRoots() {
        guard let template = templateStore.activeTemplate else { return }
        for root in managedFolderURLs { metadataStore.applyTemplate(template, to: root) }
    }

    /// Usa gli ID stabili dei `FieldTemplate` per riconoscere lo stesso campo anche quando viene
    /// rinominato. Aggiorna ogni radice; le sottocartelle ricevono immediatamente il risultato
    /// tramite ereditarietà. Le vecchie opzioni vengono mantenute per non invalidare valori già
    /// assegnati.
    private func propagateTemplateUpdate(from previous: MetadataTemplate, to updated: MetadataTemplate) {
        for root in managedFolderURLs {
            let currentFields = metadataStore.fields(for: root, configurationRootURL: root)
            for updatedField in updated.fields {
                guard let previousField = previous.fields.first(where: { $0.id == updatedField.id }),
                      let existing = currentFields.first(where: {
                          $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                              == previousField.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                      }) else { continue }
                var options = updatedField.options
                var labels = Set(options.map { $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
                for option in existing.options {
                    let key = option.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    if labels.insert(key).inserted { options.append(option) }
                }
                metadataStore.updateField(
                    folderURL: root,
                    field: existing,
                    name: updatedField.name,
                    kind: updatedField.kind,
                    options: options
                )
            }
            metadataStore.applyTemplate(updated, to: root)
        }
    }

    private func cleanMetadataDatabase() {
        isReconciling = true
        metadataStore.reconcileManagedFiles { relocated, missingIdentities in
            let removed = metadataStore.purge(identities: missingIdentities)
            isReconciling = false
            maintenanceOrphans = 0
            maintenanceOrphanIdentities = []
            maintenanceMessage = "\(L("maint.updated")) \(relocated) · \(L("maint.removedPrefix")) \(removed) \(L("maint.orphanMetadataSuffix"))"
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            checkForUpdates()
                        } label: {
                            Label(L("update.check"), systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isCheckingUpdate)

                        if isCheckingUpdate {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    updateStatusView

                    Divider()

                    Toggle(L("update.autoToggle"), isOn: $autoCheckUpdates)
                        .toggleStyle(.checkbox)

                    Text(L("update.autoNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("update.card"), systemImage: "arrow.down.circle")
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

    private var isCheckingUpdate: Bool {
        if case .checking = updateState { return true }
        return false
    }

    private func checkForUpdates() {
        updateState = .checking
        UpdateService.checkForUpdate { result in
            switch result {
            case let .upToDate(current):
                updateState = .upToDate(current)
            case let .updateAvailable(latest, _, releaseURL, downloadURL):
                updateState = .available(latest: latest, releaseURL: releaseURL, downloadURL: downloadURL)
            case let .failed(message):
                updateState = .failed(message)
            }
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateState {
        case .idle, .checking:
            EmptyView()
        case let .upToDate(current):
            Label("\(L("update.upToDatePrefix")) \(current)", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case let .available(latest, releaseURL, downloadURL):
            VStack(alignment: .leading, spacing: 8) {
                Label("\(L("update.availablePrefix")) \(latest)", systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(accent)

                Button {
                    NSWorkspace.shared.open(downloadURL ?? releaseURL)
                } label: {
                    Label(L("update.download"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.bordered)
            }
        case let .failed(message):
            Label("\(L("update.failedPrefix")) \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
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

/// Editor multilinea di una nota nel pannello della sidebar. Tiene una copia locale del testo
/// (come le celle della tabella) per non ri-renderizzarsi ad ogni notifica dello store durante
/// la digitazione; si risincronizza quando cambia l'item o il campo (`identityKey`). Il tasto
/// Invio termina la modifica (rimuove il focus) invece di inserire un a capo.
private struct NoteFieldEditor: View {
    let fontSize: Double
    let identityKey: String
    let initialValue: String
    let onChange: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: fontSize))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 60)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .focused($focused)
            .onKeyPress(.return) {
                // Invio: termina l'editing (niente a capo). Per un a capo usare Opt/Shift+Invio.
                focused = false
                return .handled
            }
            .onChange(of: text) { _, newValue in
                onChange(newValue)
            }
            // Cambiando file (o campo) ricarica il testo salvato senza propagarlo come modifica.
            .task(id: identityKey) {
                text = initialValue
            }
    }
}

/// Editor a riga singola per campi numero/link. Copia locale del testo con risincronizzazione
/// su `identityKey`; Invio conferma e chiude l'editing. Per i link mostra un pulsante di apertura.
private struct SidebarLineEditor: View {
    let fontSize: Double
    let identityKey: String
    let initialValue: String
    var placeholder = ""
    var showsOpenButton = false
    let onChange: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .focused($focused)
                .onSubmit { focused = false }
                .onChange(of: text) { _, newValue in onChange(newValue) }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))

            if showsOpenButton {
                Button {
                    openLink()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task(id: identityKey) { text = initialValue }
    }

    private func openLink() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if let url = URL(string: raw), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
    }
}

/// Editor per un campo data, con lo stesso comportamento delle note: a riposo mostra solo la
/// data (o un box bianco se vuota); al clic entra in editing con lo stepper field (giorno/mese/
/// anno che scorrono con le frecce). Cliccando altrove l'editing termina.
private struct SidebarDateEditor: View {
    @Binding var value: String
    @State private var isEditing = false
    @State private var isHovering = false
    @FocusState private var focused: Bool

    private var date: Date? { MetadataValueFormatter.date(from: value) }

    private var isExpired: Bool {
        guard let date else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: date) < calendar.startOfDay(for: Date())
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { date ?? Date() },
            set: { value = MetadataValueFormatter.string(from: $0) }
        )
    }

    var body: some View {
        Group {
            if isEditing {
                DatePicker("", selection: dateBinding, displayedComponents: .date)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .focused($focused)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { isEditing = false }
                    }
            } else if value.isEmpty {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEditing() }
            } else {
                HStack(spacing: 4) {
                    Text(MetadataValueFormatter.displayDate(from: value))
                        .foregroundStyle(isExpired ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture { beginEditing() }

                    if isHovering {
                        Button {
                            value = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                .onHover { isHovering = $0 }
            }
        }
    }

    private func beginEditing() {
        if value.isEmpty { value = MetadataValueFormatter.string(from: Date()) }
        isEditing = true
        DispatchQueue.main.async { focused = true }
    }
}

/// Editor per campi select/kanban con lo STESSO aspetto della tabella: mostra il tag colorato
/// (capsula) e, al clic, un menù nascosto sovrapposto permette di cambiare opzione.
private struct SidebarSelectEditor: View {
    let field: MetadataField
    @Binding var value: String

    private var selected: MetadataSelectOption {
        field.options.first { $0.label == value } ?? MetadataSelectOption(label: value, color: .gray)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Picker("", selection: $value) {
                Text(L("common.empty")).tag("")
                ForEach(field.options) { option in
                    Text(option.label).tag(option.label)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .opacity(0.02)
            .frame(maxWidth: .infinity, alignment: .leading)

            if value.isEmpty {
                // Campo vuoto: box bianco (come i campi testo/data), senza scritta e senza contorno.
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .frame(height: 22)
                    .allowsHitTesting(false)
            } else {
                MetadataTagView(label: selected.label, color: selected.color)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Applica una larghezza fissa alla cella del campo, oppure la lascia estendere a tutta la
/// larghezza disponibile quando `width` è nil (usato per le note libere).
private struct FieldWidth: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, alignment: .leading)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Layout a flusso: dispone le sottoviste in orizzontale mandandole a capo quando non c'è più
/// spazio, rispettando la larghezza intrinseca di ciascuna (celle dei campi affiancate).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: maxWidth.isFinite ? maxWidth : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, projected > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
                current.height = max(current.height, size.height)
                current.indices.append(index)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

private struct FolderIndexSnapshot {
    var status: FolderIndexStatus = .unknown
    var checkedAt: Date?
    var isChecking = false
}

private struct SettingsWindowContainer: View {
    @State private var section: SettingsSection = .folders
    @AppStorage(AIProviderSettings.Keys.enabled) private var aiEnabled = true
    let accent: Color
    let dismiss: () -> Void
    let detail: (SettingsSection) -> AnyView

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("sidebar.configuration"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                ForEach(SettingsSection.allCases) { item in
                    let selected = section == item
                    let unavailable = item == .contentIndexing && !aiEnabled
                    Button { section = item } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.systemImage)
                                .font(.body).frame(width: 20)
                                .foregroundStyle(selected ? Color.white : accent)
                            Text(item.title)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .lineLimit(1).minimumScaleFactor(0.82)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? accent : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(unavailable)
                    .opacity(unavailable ? 0.42 : 1)
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 210)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()
            detail(section)
        }
        .frame(width: 760, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .onChange(of: aiEnabled) { _, enabled in
            if !enabled, section == .contentIndexing { section = .indexing }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case folders
    case appearance
    case display
    case startup
    case language
    case templates
    case indexing
    case contentIndexing
    case maintenance
    case backup
    case help
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folders:
            return L("settings.folders.title")
        case .appearance:
            return L("settings.appearance.title")
        case .display:
            return L("settings.display.title")
        case .startup:
            return L("settings.startup.title")
        case .language:
            return L("settings.language.title")
        case .templates:
            return L("settings.templates.title")
        case .contentIndexing:
            return L("settings.contentIndexing.title")
        case .indexing:
            return L("settings.indexing.title")
        case .maintenance:
            return L("settings.maintenance.title")
        case .backup:
            return L("settings.backup.title")
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
        case .display:
            return "eye"
        case .startup:
            return "power"
        case .language:
            return "globe"
        case .templates:
            return "rectangle.stack"
        case .contentIndexing:
            return "doc.text.magnifyingglass"
        case .indexing:
            return "sparkles"
        case .maintenance:
            return "wrench.and.screwdriver"
        case .backup:
            return "externaldrive"
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
        case .display:
            return L("settings.display.subtitle")
        case .startup:
            return L("settings.startup.subtitle")
        case .language:
            return L("settings.language.subtitle")
        case .templates:
            return L("settings.templates.subtitle")
        case .contentIndexing:
            return L("settings.contentIndexing.subtitle")
        case .indexing:
            return L("settings.indexing.subtitle")
        case .maintenance:
            return L("settings.maintenance.subtitle")
        case .backup:
            return L("settings.backup.subtitle")
        case .help:
            return L("settings.help.subtitle")
        case .support:
            return L("settings.support.subtitle")
        }
    }
}

/// Stato del controllo aggiornamenti mostrato nella sezione "Info su FolderBase".
private enum UpdateUIState {
    case idle
    case checking
    case upToDate(String)
    case available(latest: String, releaseURL: URL, downloadURL: URL?)
    case failed(String)
}

/// Sezione "Struttura" della sidebar (gli alberi delle cartelle gestite), estratta in un subview
/// `Equatable` per isolarla dai re-render della `SidebarView`. Con `.equatable()` SwiftUI salta la
/// ricostruzione dell'albero quando gli input di valore (radici, selezione, font) non cambiano,
/// anche se la sidebar si rivaluta per altri motivi (progresso indicizzazione, backup, metadati).
/// La reattività ai contenuti delle cartelle resta garantita dai `DirectoryTreeView`, che osservano
/// `directoryCache` per conto proprio. Le closure e i reference type (store/cache) NON entrano nel
/// confronto di uguaglianza: sono stabili per l'intera vita della finestra.
struct SidebarTreeSection: View, Equatable {
    let rootURLs: [URL]
    let selectedFolderURL: URL?
    let fontSize: Double
    let treeRootURL: URL?
    let onSelect: (URL) -> Void
    let onMoveItems: ([String], URL) -> Void
    let onRemoveRoot: (URL) -> Void
    let onAction: (URL, DirectoryTreeAction) -> Void
    let metadataStore: MetadataStore
    let chatService: ChatService
    let directoryCache: DirectorySnapshotCache

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rootURLs, id: \.path) { rootURL in
                DirectoryTreeView(
                    rootURL: rootURL,
                    selectedFolderURL: selectedFolderURL,
                    fontSize: fontSize,
                    onSelect: onSelect,
                    onMoveItems: onMoveItems,
                    onRemoveRoot: onRemoveRoot,
                    configurationRootURL: treeRootURL,
                    onAction: onAction,
                    metadataStore: metadataStore,
                    chatService: chatService,
                    directoryCache: directoryCache
                )
                .id(rootURL.path)
            }
        }
    }

    static func == (lhs: SidebarTreeSection, rhs: SidebarTreeSection) -> Bool {
        lhs.rootURLs == rhs.rootURLs
            && lhs.selectedFolderURL == rhs.selectedFolderURL
            && lhs.fontSize == rhs.fontSize
            && lhs.treeRootURL == rhs.treeRootURL
    }
}
