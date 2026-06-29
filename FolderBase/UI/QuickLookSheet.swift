import Quartz
import SwiftUI

/// Foglio di anteprima rapida (Quick Look) per un singolo file.
struct QuickLookSheet: View {
    let url: URL
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Fine", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            QuickLookPreview(url: url)
                .frame(minWidth: 640, minHeight: 480)
        }
        .frame(width: 760, height: 620)
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if nsView.previewItem?.previewItemURL != url {
            nsView.previewItem = url as NSURL
        }
    }
}
