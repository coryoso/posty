import Foundation

enum SQLIdentifier {
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func qualified(_ schema: String, _ name: String) -> String {
        "\(quote(schema)).\(quote(name))"
    }
}

