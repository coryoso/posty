import AppKit
import SwiftUI

struct SQLDiffView: NSViewRepresentable {
    let original: String
    let proposed: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        update(textView)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView)
    }

    private func update(_ textView: NSTextView) {
        let result = NSMutableAttributedString()
        for line in LineDiff.lines(from: original, to: proposed) {
            let prefix: String
            let color: NSColor
            let background: NSColor
            switch line.kind {
            case .same:
                prefix = "  "; color = .labelColor; background = .clear
            case .removed:
                prefix = "− "; color = .systemRed; background = .systemRed.withAlphaComponent(0.10)
            case .added:
                prefix = "+ "; color = .systemGreen; background = .systemGreen.withAlphaComponent(0.10)
            }
            result.append(NSAttributedString(string: prefix + line.text + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
                .backgroundColor: background
            ]))
        }
        if textView.attributedString() != result { textView.textStorage?.setAttributedString(result) }
    }
}

private enum LineDiff {
    enum Kind { case same, removed, added }
    struct Line { let kind: Kind; let text: String }

    static func lines(from old: String, to new: String) -> [Line] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty, !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }
        var result: [Line] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                result.append(Line(kind: .same, text: a[i])); i += 1; j += 1
            } else if j < b.count, (i == a.count || lengths[i][j + 1] >= lengths[i + 1][j]) {
                result.append(Line(kind: .added, text: b[j])); j += 1
            } else if i < a.count {
                result.append(Line(kind: .removed, text: a[i])); i += 1
            }
        }
        return result
    }
}
