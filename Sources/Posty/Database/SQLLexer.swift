import Foundation

struct SQLStatement: Identifiable, Hashable, Sendable {
    enum Safety: Hashable, Sendable { case readOnly, potentiallyWriting }

    let id = UUID()
    let sql: String
    let range: Range<String.Index>
    let safety: Safety
}

enum SQLLexer {
    private enum State: Equatable {
        case normal
        case singleQuote
        case doubleQuote
        case lineComment
        case blockComment(depth: Int)
        case dollarQuote(tag: String)
    }

    static func statements(in source: String) -> [SQLStatement] {
        var state = State.normal
        var index = source.startIndex
        var statementStart = source.startIndex
        var ranges: [Range<String.Index>] = []

        while index < source.endIndex {
            let next = source.index(after: index)
            let character = source[index]
            let following = next < source.endIndex ? source[next] : nil

            switch state {
            case .normal:
                if character == "'" { state = .singleQuote }
                else if character == "\"" { state = .doubleQuote }
                else if character == "-", following == "-" {
                    state = .lineComment
                    index = next
                } else if character == "/", following == "*" {
                    state = .blockComment(depth: 1)
                    index = next
                } else if character == "$", let tag = dollarTag(at: index, in: source) {
                    state = .dollarQuote(tag: tag)
                    index = source.index(index, offsetBy: tag.count - 1)
                } else if character == ";" {
                    ranges.append(statementStart..<next)
                    statementStart = next
                }
            case .singleQuote:
                if character == "'" {
                    if following == "'" { index = next } else { state = .normal }
                }
            case .doubleQuote:
                if character == "\"" {
                    if following == "\"" { index = next } else { state = .normal }
                }
            case .lineComment:
                if character == "\n" { state = .normal }
            case .blockComment(let depth):
                if character == "/", following == "*" {
                    state = .blockComment(depth: depth + 1)
                    index = next
                } else if character == "*", following == "/" {
                    state = depth == 1 ? .normal : .blockComment(depth: depth - 1)
                    index = next
                }
            case .dollarQuote(let tag):
                if source[index...].hasPrefix(tag) {
                    index = source.index(index, offsetBy: tag.count - 1)
                    state = .normal
                }
            }
            index = source.index(after: index)
        }

        if statementStart < source.endIndex { ranges.append(statementStart..<source.endIndex) }
        return ranges.compactMap { range in
            let sql = source[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sql.isEmpty, containsExecutableText(sql) else { return nil }
            return SQLStatement(sql: sql, range: range, safety: safety(of: sql))
        }
    }

    static func statement(at utf16Location: Int, in source: String) -> SQLStatement? {
        let target = String.Index(utf16Offset: min(utf16Location, source.utf16.count), in: source)
        return statements(in: source).first(where: { $0.range.contains(target) }) ?? statements(in: source).last
    }

    static func safety(of sql: String) -> SQLStatement.Safety {
        let tokens = significantTokens(in: sql)
        guard let first = tokens.first else { return .readOnly }
        switch first {
        case "SELECT", "TABLE", "VALUES", "SHOW":
            let writing = Set([
                "INSERT", "UPDATE", "DELETE", "MERGE", "CALL", "COPY", "CREATE", "ALTER", "DROP",
                "TRUNCATE", "GRANT", "REVOKE", "VACUUM", "REINDEX", "CLUSTER", "REFRESH", "DO",
                "INTO", "NEXTVAL", "SETVAL", "PG_ADVISORY_LOCK", "PG_WRITE_FILE", "LO_IMPORT"
            ])
            return tokens.contains(where: writing.contains) ? .potentiallyWriting : .readOnly
        case "EXPLAIN":
            return tokens.contains("ANALYZE") ? .potentiallyWriting : .readOnly
        default:
            return .potentiallyWriting
        }
    }

    static func modifiesSchema(_ sql: String) -> Bool {
        guard let first = significantTokens(in: sql).first else { return false }
        return ["CREATE", "ALTER", "DROP", "TRUNCATE", "COMMENT", "GRANT", "REVOKE", "REINDEX", "CLUSTER", "REFRESH"].contains(first)
    }

    static func significantTokens(in source: String) -> [String] {
        var result: [String] = []
        var current = ""
        var state = State.normal
        var index = source.startIndex

        func flush() {
            if !current.isEmpty {
                result.append(current.uppercased())
                current = ""
            }
        }

        while index < source.endIndex {
            let next = source.index(after: index)
            let character = source[index]
            let following = next < source.endIndex ? source[next] : nil
            switch state {
            case .normal:
                if character.isLetter || character == "_" { current.append(character) }
                else {
                    flush()
                    if character == "'" { state = .singleQuote }
                    else if character == "\"" { state = .doubleQuote }
                    else if character == "-", following == "-" { state = .lineComment; index = next }
                    else if character == "/", following == "*" { state = .blockComment(depth: 1); index = next }
                    else if character == "$", let tag = dollarTag(at: index, in: source) {
                        state = .dollarQuote(tag: tag)
                        index = source.index(index, offsetBy: tag.count - 1)
                    }
                }
            case .singleQuote:
                if character == "'" {
                    if following == "'" { index = next } else { state = .normal }
                }
            case .doubleQuote:
                if character == "\"" {
                    if following == "\"" { index = next } else { state = .normal }
                }
            case .lineComment:
                if character == "\n" { state = .normal }
            case .blockComment(let depth):
                if character == "/", following == "*" { state = .blockComment(depth: depth + 1); index = next }
                else if character == "*", following == "/" { state = depth == 1 ? .normal : .blockComment(depth: depth - 1); index = next }
            case .dollarQuote(let tag):
                if source[index...].hasPrefix(tag) {
                    index = source.index(index, offsetBy: tag.count - 1)
                    state = .normal
                }
            }
            index = source.index(after: index)
        }
        flush()
        return result
    }

    private static func dollarTag(at index: String.Index, in source: String) -> String? {
        guard source[index] == "$" else { return nil }
        var cursor = source.index(after: index)
        while cursor < source.endIndex, source[cursor].isLetter || source[cursor].isNumber || source[cursor] == "_" {
            cursor = source.index(after: cursor)
        }
        guard cursor < source.endIndex, source[cursor] == "$" else { return nil }
        return String(source[index...cursor])
    }

    private static func containsExecutableText(_ sql: String) -> Bool {
        !significantTokens(in: sql).isEmpty
    }
}
