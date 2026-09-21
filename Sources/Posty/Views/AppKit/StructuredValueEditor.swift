@preconcurrency import AppKit
import SwiftUI

struct CellEditorRequest: Identifiable {
    let id = UUID()
    let rowID: UUID
    let columnIndex: Int
    let columnName: String
    let value: DatabaseValue
}

struct DatabaseValueEditorSheet: View {
    let request: CellEditorRequest
    let apply: (DatabaseValue) -> Void
    let cancel: () -> Void
    @State private var text: String
    @State private var errorMessage: String?

    init(request: CellEditorRequest, apply: @escaping (DatabaseValue) -> Void, cancel: @escaping () -> Void) {
        self.request = request
        self.apply = apply
        self.cancel = cancel
        _text = State(initialValue: request.value.prettyEditingString)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: titleIcon)
                Text(request.columnName).font(.headline)
                Spacer()
            }
            .padding(14)
            Divider()
            StructuredTextEditor(text: $text, highlightsJSON: isJSON)
                .padding(12)
            Divider()
            HStack {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Apply") {
                    do { apply(try request.value.replacingDisplayValue(with: text)) }
                    catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(minWidth: 680, minHeight: 500)
    }

    private var isJSON: Bool {
        if case .json = request.value { return true }
        return false
    }

    private var titleIcon: String {
        switch request.value {
        case .json: "curlybraces.square"
        case .array: "square.stack.3d.up"
        case .binary: "doc.zipper"
        default: "text.alignleft"
        }
    }
}

private struct StructuredTextEditor: NSViewRepresentable {
    @Binding var text: String
    let highlightsJSON: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 650, height: 420))
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.delegate = context.coordinator
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        context.coordinator.isUpdating = true
        textView.string = text
        context.coordinator.isUpdating = false
        context.coordinator.highlight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StructuredTextEditor
        weak var textView: NSTextView?
        var isUpdating = false
        private var isHighlighting = false

        init(_ parent: StructuredTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            parent.text = textView.string
            highlight()
        }

        func highlight() {
            guard parent.highlightsJSON, !isHighlighting, let textView, let storage = textView.textStorage else { return }
            isHighlighting = true
            let selection = textView.selectedRange()
            let source = textView.string
            let full = NSRange(location: 0, length: (source as NSString).length)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: full)
            apply(#"\"(?:\\.|[^\"\\])*\""#, color: .systemGreen, source: source, storage: storage)
            apply(#"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, color: .systemBlue, source: source, storage: storage)
            apply(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemPurple, source: source, storage: storage)
            apply(#"\b(true|false|null)\b"#, color: .systemOrange, source: source, storage: storage)
            storage.endEditing()
            textView.setSelectedRange(selection)
            isHighlighting = false
        }

        private func apply(_ pattern: String, color: NSColor, source: String, storage: NSTextStorage) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            regex.enumerateMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
    }
}
