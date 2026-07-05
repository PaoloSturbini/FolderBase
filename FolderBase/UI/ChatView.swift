import AppKit
import SwiftUI

/// Pannello di chat con i propri documenti (RAG). Mostra la conversazione con risposta in
/// streaming e le fonti citate (cliccabili → Finder).
struct ChatView: View {
    @ObservedObject var chatService: ChatService
    @ObservedObject private var loc = LocalizationManager.shared
    let candidates: Set<String>
    let store: MetadataStore
    let dismiss: () -> Void

    @State private var input = ""

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
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }

            Divider()
            inputBar
        }
        .frame(width: 580, height: 640)
    }

    private var header: some View {
        HStack {
            Label(L("chat.title"), systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
            Spacer()
            Button {
                chatService.reset()
            } label: {
                Label(L("chat.new"), systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(chatService.messages.isEmpty || chatService.isBusy)

            Button(L("common.done")) { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        chatService.ask(question, candidates: candidates, store: store)
    }
}
