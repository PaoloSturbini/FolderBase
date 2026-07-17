import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pannello di chat con i propri documenti (RAG). Mostra la conversazione con risposta in
/// streaming e le fonti citate (cliccabili → Finder). L'ambito (tutto l'indice / cartella / file)
/// è gestito da `chatService` (vedi `configure`).
struct ChatView: View {
    @ObservedObject var chatService: ChatService
    @ObservedObject private var loc = LocalizationManager.shared
    let store: MetadataStore
    /// File che era selezionato quando la chat è stata aperta. Non segue le selezioni
    /// successive della tabella, così l'utente sa sempre quale documento verrà interrogato.
    let focusedFile: FileItem?
    let dismiss: () -> Void

    @State private var input = ""
    /// Fornitore di chat corrente (persistito nelle stesse impostazioni della Configurazione:
    /// qui si cambia solo il FORNITORE, il modello specifico resta quello impostato là).
    @AppStorage(AIProviderSettings.Keys.chatProvider) private var chatProviderRaw = AIChatProvider.none.rawValue

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !chatService.isConfigured {
                notConfiguredBanner
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chatService.messages.isEmpty {
                            Text(L("chat.intro"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        }
                        ForEach(chatService.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: chatService.messages.last?.text) {
                    if let lastID = chatService.messages.last?.id {
                        // Durante lo streaming lo scroll NON è animato (animare a ogni flush di
                        // token è costoso e produce scatti); si anima solo a risposta conclusa.
                        if chatService.isBusy {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        } else {
                            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                }
            }

            Divider()
            inputBar
        }
        .frame(width: 580, height: 640)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Label(L("chat.title"), systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                scopeMenu
            }
            Spacer()

            chatProviderMenu

            Button {
                chatService.rerun(store: store)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!chatService.canRerun)

            Button {
                copyConversation()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(!chatService.hasConversation)

            Button {
                exportConversation()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!chatService.hasConversation)

            Button {
                chatService.reset()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(!chatService.hasConversation || chatService.isBusy)

            Button(L("common.done")) { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private enum ScopeChoice: String {
        case all
        case file
    }

    /// Se la chat è stata aperta con un file selezionato, permette di passare tra tutto
    /// l'indice e quel solo file. Cambiare contesto azzera intenzionalmente la conversazione.
    @ViewBuilder
    private var scopeMenu: some View {
        if let focusedFile {
            Menu {
                Picker(L("chat.scope.pick"), selection: scopeChoiceBinding) {
                    Text(L("chat.scope.all")).tag(ScopeChoice.all)
                    Text("\(L("chat.scope.file")): \(focusedFile.name)").tag(ScopeChoice.file)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 3) {
                    Text("\(L("chat.scope.label")): \(chatService.scopeLabel)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        } else if !chatService.scopeLabel.isEmpty {
            Text("\(L("chat.scope.label")): \(chatService.scopeLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var scopeChoiceBinding: Binding<ScopeChoice> {
        Binding(
            get: { chatService.isWholeIndexScope ? .all : .file },
            set: { choice in
                guard let focusedFile else { return }
                switch choice {
                case .all:
                    chatService.configure(candidates: [], scopeLabel: L("chat.scope.all"))
                case .file:
                    chatService.configure(
                        candidates: [focusedFile.identity],
                        scopeLabel: "\(L("chat.scope.file")): \(focusedFile.name)"
                    )
                }
            }
        )
    }

    /// Menu per cambiare al volo il FORNITORE di chat (Ollama / OpenAI). Apple è mostrato ma
    /// disabilitato: su macOS 14 non esiste un modello di chat on-device. Il modello specifico
    /// di ciascun fornitore resta quello impostato in Configurazione.
    private var chatProviderMenu: some View {
        Menu {
            Picker(L("chat.provider.pick"), selection: $chatProviderRaw) {
                Text(L("ai.provider.ollama")).tag(AIChatProvider.ollama.rawValue)
                Text(L("ai.provider.openai")).tag(AIChatProvider.openai.rawValue)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Button {} label: { Text(L("chat.provider.appleUnavailable")) }
                .disabled(true)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                Text(chatProviderLabel).font(.caption)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var chatProviderLabel: String {
        switch AIChatProvider(rawValue: chatProviderRaw) ?? .none {
        case .none: return L("ai.chat.none")
        case .ollama: return L("ai.provider.ollama")
        case .openai: return L("ai.provider.openai")
        }
    }

    /// Copia l'intera conversazione (Markdown) negli appunti.
    private func copyConversation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chatService.transcriptMarkdown(), forType: .string)
    }

    /// Esporta la conversazione in un file Markdown scelto dall'utente.
    private func exportConversation() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "chat-\(formatter.string(from: Date())).md"
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? chatService.transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
    }

    private var notConfiguredBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L("chat.needProvider"))
                .font(.callout)
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func messageRow(_ message: ChatService.Message) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            Text(message.text.isEmpty && message.role == .assistant ? "…" : message.text)
                .textSelection(.enabled)
                .padding(10)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("chat.sources"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, source in
                        Button {
                            NSWorkspace.shared.selectFile(source.path, inFileViewerRootedAtPath: "")
                        } label: {
                            HStack(spacing: 4) {
                                Text("[\(index + 1)]").foregroundStyle(.secondary)
                                Image(systemName: "doc")
                                Text(source.name).lineLimit(1)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            messageActions(message)
        }
    }

    /// Barra di azioni in fondo a ogni messaggio (allineata al lato del messaggio): copia il
    /// messaggio e, sui messaggi utente, rilancia quella domanda; sulle risposte, rigenera.
    @ViewBuilder
    private func messageActions(_ message: ChatService.Message) -> some View {
        if !(message.role == .assistant && message.text.isEmpty) {
            HStack(spacing: 12) {
                Button {
                    copyText(message.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)

                Button {
                    if message.role == .user {
                        chatService.ask(message.text, store: store)
                    } else {
                        regenerate(message)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(chatService.isBusy)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        }
    }

    /// Copia un singolo messaggio negli appunti.
    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Rigenera una risposta: ripone la domanda utente che l'ha preceduta.
    private func regenerate(_ assistant: ChatService.Message) {
        guard let index = chatService.messages.firstIndex(where: { $0.id == assistant.id }) else { return }
        if let question = chatService.messages[..<index].last(where: { $0.role == .user })?.text {
            chatService.ask(question, store: store)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(L("chat.placeholder"), text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit(send)
                .disabled(!chatService.isConfigured)

            if chatService.isBusy {
                Button {
                    chatService.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chatService.isConfigured)
            }
        }
        .padding(12)
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        input = ""
        chatService.ask(question, store: store)
    }
}
