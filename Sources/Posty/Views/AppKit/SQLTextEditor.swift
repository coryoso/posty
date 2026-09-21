@preconcurrency import AppKit
import SwiftUI

struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedText: String
    @Binding var cursorUTF16Location: Int
    let completions: [String]
    let editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CompletingTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 420))
        textView.isRichText = false
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator
        textView.completionCandidates = completions
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.identifier = NSUserInterfaceItemIdentifier("sqlEditor")
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.hasHorizontalRuler = false
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.verticalRulerView = LineNumberRulerView(textView: textView)
        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CompletingTextView else { return }
        textView.isEditable = editable
        textView.completionCandidates = completions
        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isUpdating = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            context.coordinator.isUpdating = false
            context.coordinator.highlight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextEditor
        weak var textView: NSTextView?
        var isUpdating = false
        private var isHighlighting = false

        init(_ parent: SQLTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            parent.text = textView.string
            updateSelection()
            highlight()
        }

        func textViewDidChangeSelection(_ notification: Notification) { updateSelection() }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("    ", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }

        func highlight() {
            guard !isHighlighting, let textView, let storage = textView.textStorage else { return }
            isHighlighting = true
            let selection = textView.selectedRange()
            let source = textView.string
            let full = NSRange(location: 0, length: (source as NSString).length)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: full)
            apply(#"\b(SELECT|FROM|WHERE|JOIN|INNER|LEFT|RIGHT|FULL|OUTER|ON|AS|AND|OR|NOT|NULL|TRUE|FALSE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|RETURNING|WITH|RECURSIVE|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|CREATE|ALTER|DROP|TABLE|VIEW|INDEX|FUNCTION|PROCEDURE|BEGIN|COMMIT|ROLLBACK|CASE|WHEN|THEN|ELSE|END|DISTINCT|UNION|ALL|EXPLAIN|ANALYZE)\b"#, color: .systemBlue, options: [.caseInsensitive], storage: storage, source: source)
            apply(#"'(?:''|[^'])*'"#, color: .systemOrange, storage: storage, source: source)
            apply(#"--[^\n]*|/\*[\s\S]*?\*/"#, color: .secondaryLabelColor, storage: storage, source: source)
            apply(#"\b\d+(?:\.\d+)?\b"#, color: .systemPurple, storage: storage, source: source)
            storage.endEditing()
            textView.setSelectedRange(selection)
            isHighlighting = false
        }

        private func apply(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = [], storage: NSTextStorage, source: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let range = NSRange(location: 0, length: (source as NSString).length)
            regex.enumerateMatches(in: source, range: range) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }

        private func updateSelection() {
            guard let textView else { return }
            let range = textView.selectedRange()
            let source = textView.string as NSString
            parent.cursorUTF16Location = range.location
            parent.selectedText = NSMaxRange(range) <= source.length ? source.substring(with: range) : ""
        }
    }
}

private final class CompletingTextView: NSTextView {
    var completionCandidates: [String] = []

    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let partial = (string as NSString).substring(with: charRange)
        let needle = partial.lowercased()
        let matching = completionCandidates.filter { needle.isEmpty || $0.lowercased().hasPrefix(needle) }
        return Array(matching.prefix(100))
    }
}

private final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.needsDisplay = true }
        })
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.needsDisplay = true }
            })
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        let visible = textView.enclosingScrollView?.contentView.bounds ?? textView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let source = textView.string as NSString
        var line = 1
        var cursor = 0
        while cursor < layoutManager.characterIndexForGlyph(at: glyphRange.location) && cursor < source.length {
            cursor = NSMaxRange(source.lineRange(for: NSRange(location: cursor, length: 0)))
            line += 1
        }
        var glyph = glyphRange.location
        while glyph < NSMaxRange(glyphRange) {
            let character = layoutManager.characterIndexForGlyph(at: glyph)
            let lineRange = source.lineRange(for: NSRange(location: character, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: container)
            let y = rect.minY + textView.textContainerInset.height - visible.minY
            let label = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 7, y: y), withAttributes: attributes)
            glyph = NSMaxRange(lineGlyphRange)
            line += 1
            if lineGlyphRange.length == 0 { break }
        }
    }
}
