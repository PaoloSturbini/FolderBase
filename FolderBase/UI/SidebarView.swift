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

struct SidebarView: View {
    let selectedFolderURL: URL?
    let recentFolderURLs: [URL]
    let treeRootURL: URL?
    let treeRefreshID: UUID
    @Binding var sidebarFontSize: Double
    @Binding var contentFontSize: Double
    @Binding var appearanceMode: String
    @Binding var showHiddenFiles: Bool
    @Binding var showFileExtensions: Bool
    let selectFolder: (URL) -> Void
    let removeFolder: (URL) -> Void
    let chooseFolder: () -> Void
    let navigateTo: (URL) -> Void
    let moveItems: ([String], URL) -> Void
    @ObservedObject var templateStore: TemplateStore
    @ObservedObject var metadataStore: MetadataStore
    @ObservedObject var backupService: BackupService
    @ObservedObject var indexingService: IndexingService
    @ObservedObject private var loc = LocalizationManager.shared

    @State private var isShowingSettings = false
    @State private var isAddingTemplate = false
    @State private var templatePendingEdit: MetadataTemplate?
    @State private var maintenanceMessage: String?
    @State private var maintenanceOrphans = 0
    /// Identità degli orfani trovati dall'ultima riconciliazione: il purge le riusa
    /// senza dover ri-risolvere tutti i file gestiti.
    @State private var maintenanceOrphanIdentities: [String] = []
    @State private var isReconciling = false
    @AppStorage("autoPurgeOrphans") private var autoPurgeOrphans = false
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = false
    @State private var settingsSection: SettingsSection = .folders
    @State private var updateState: UpdateUIState = .idle
    @State private var backupMessage: String?
    @State private var backupFailed = false
    @State private var isConfirmingRestore = false
    @State private var pendingRestoreURL: URL?
    @State private var indexStatus: FolderIndexStatus = .unknown
    @State private var isCheckingIndexStatus = false
    @State private var indexStatusCheckedAt: Date?
    @AppStorage(AIProviderSettings.Keys.provider) private var aiProviderRaw = AIEmbeddingProvider.apple.rawValue
    @AppStorage(AIProviderSettings.Keys.ollamaBaseURL) private var aiOllamaBaseURL = AIProviderSettings.defaultOllamaBaseURL
    @AppStorage(AIProviderSettings.Keys.ollamaModel) private var aiOllamaModel = AIProviderSettings.defaultOllamaModel
    @AppStorage(AIProviderSettings.Keys.openAIModel) private var aiOpenAIModel = AIProviderSettings.defaultOpenAIModel
    @State private var openAIKeyInput = ""
    @State private var hasOpenAIKey = false
    @State private var aiTesting = false
    @State private var aiTestMessage: String?
    @AppStorage(AIProviderSettings.Keys.chatProvider) private var aiChatProviderRaw = AIChatProvider.none.rawValue
    @AppStorage(AIProviderSettings.Keys.ollamaChatModel) private var aiOllamaChatModel = AIProviderSettings.defaultOllamaChatModel
    @AppStorage(AIProviderSettings.Keys.openAIChatModel) private var aiOpenAIChatModel = AIProviderSettings.defaultOpenAIChatModel
    @State private var chatTesting = false
    @State private var chatTestMessage: String?

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
                    case .display:
                        displaySettings
                    case .language:
                        languageSettings
                    case .templates:
                        templatesSettings
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

    private var indexingSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("indexing.intro"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let selectedFolderURL {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(indexStatusColor)
                                .frame(width: 10, height: 10)
                            Text(indexStatusLabel)
                                .font(.callout)
                            if isCheckingIndexStatus {
                                ProgressView().controlSize(.mini)
                            } else {
                                Button {
                                    Task { await recomputeStatus() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .disabled(indexingService.isIndexing)
                                .help(L("indexing.recheck"))
                            }
                        }

                        if let checkedAt = indexStatusCheckedAt {
                            Text("\(L("indexing.checkedAt")) \(Self.statusDateFormatter.string(from: checkedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button {
                                indexingService.indexRecursively(root: selectedFolderURL, store: metadataStore)
                            } label: {
                                Label(indexButtonTitle, systemImage: "sparkles")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(indexingService.isIndexing)

                            if indexingService.isIndexing {
                                ProgressView().controlSize(.small)
                                Text(indexingProgressText)
                                    .font(.callout)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Button {
                                    indexingService.cancel()
                                } label: {
                                    Label(L("index.stop"), systemImage: "stop.circle")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        Text(L("indexing.noFolder"))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("indexing.card"), systemImage: "text.magnifyingglass")
            }

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
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("ai.chat.card"), systemImage: "bubble.left.and.bubble.right")
            }
        }
        .task(id: selectedFolderURL?.path ?? "") {
            loadCachedStatus()
        }
        .onAppear {
            hasOpenAIKey = KeychainStore.exists(account: AIProviderSettings.openAIKeyAccount)
        }
        .onChange(of: aiProviderRaw) { _, _ in
            aiTestMessage = nil
            // Lo stato dipende dal motore: al cambio provider lo si ricalcola.
            Task { await recomputeStatus() }
        }
        .onChange(of: aiChatProviderRaw) { _, _ in
            chatTestMessage = nil
        }
        .onChange(of: indexingService.isIndexing) { _, running in
            // A fine indicizzazione ricalcola e memorizza lo stato (così diventa verde da solo).
            if !running {
                Task { await recomputeStatus() }
            }
        }
    }

    private func saveOpenAIKey() {
        KeychainStore.save(openAIKeyInput, account: AIProviderSettings.openAIKeyAccount)
        hasOpenAIKey = !openAIKeyInput.isEmpty
        openAIKeyInput = ""
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
                for try await token in chat.stream(system: "Rispondi con una sola parola.", user: "Scrivi: OK") {
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
    private func loadCachedStatus() {
        guard let selectedFolderURL else {
            indexStatus = .notIndexed
            indexStatusCheckedAt = nil
            return
        }
        if let cached = indexingService.loadStatus(root: selectedFolderURL, store: metadataStore) {
            indexStatus = cached.status
            indexStatusCheckedAt = cached.checkedAt
        } else {
            indexStatus = .unknown
            indexStatusCheckedAt = nil
        }
    }

    /// Ricalcola lo stato enumerando il sottoalbero e lo memorizza (su richiesta / a fine indicizzazione).
    private func recomputeStatus() async {
        guard let selectedFolderURL else { return }
        isCheckingIndexStatus = true
        indexStatus = await indexingService.recomputeStatus(root: selectedFolderURL, store: metadataStore)
        indexStatusCheckedAt = Date()
        isCheckingIndexStatus = false
    }

    private static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var indexStatusColor: Color {
        switch indexStatus {
        case .upToDate:
            return .green
        case .stale:
            return .orange
        case .notIndexed, .unknown:
            return .gray
        }
    }

    private var indexStatusLabel: String {
        if isCheckingIndexStatus { return L("indexing.status.checking") }
        switch indexStatus {
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

    private var indexButtonTitle: String {
        if case .notIndexed = indexStatus { return L("indexing.button") }
        if case .unknown = indexStatus { return L("indexing.button") }
        return L("indexing.reindex")
    }

    private var indexingProgressText: String {
        guard let progress = indexingService.progress else { return "" }
        if progress.total == 0 { return L("indexing.scanning") }
        return "\(progress.processed)/\(progress.total)"
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

                    Text("\(L("backup.lastPrefix")) \(lastBackupText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
        do {
            let url = try backupService.runBackup(auto: false)
            backupFailed = false
            backupMessage = "\(L("backup.donePrefix")) \(url.lastPathComponent)"
        } catch {
            backupFailed = true
            backupMessage = "\(L("backup.errorPrefix")) \(error.localizedDescription)"
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
        do {
            try backupService.restore(from: url)
            backupFailed = false
            backupMessage = L("backup.restore.done")
        } catch {
            backupFailed = true
            backupMessage = "\(L("backup.errorPrefix")) \(error.localizedDescription)"
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                settingsCardLabel(L("display.card"), systemImage: "eye")
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
                    .foregroundStyle(Color.accentColor)

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

private enum SettingsSection: String, CaseIterable, Identifiable {
    case folders
    case appearance
    case display
    case language
    case templates
    case indexing
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
        case .language:
            return L("settings.language.title")
        case .templates:
            return L("settings.templates.title")
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
        case .language:
            return "globe"
        case .templates:
            return "rectangle.stack"
        case .indexing:
            return "text.magnifyingglass"
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
        case .language:
            return L("settings.language.subtitle")
        case .templates:
            return L("settings.templates.subtitle")
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
