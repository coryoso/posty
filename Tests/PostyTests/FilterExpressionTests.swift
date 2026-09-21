import Foundation
import Testing
@testable import Posty

struct FilterExpressionTests {
    @Test func compilesNestedParameterizedExpression() throws {
        let expression = FilterExpression.group(id: UUID(), junction: .and, children: [
            .predicate(id: UUID(), column: "age", typeName: "int4", operation: .greaterThan, values: ["20"]),
            .predicate(id: UUID(), column: "name", typeName: "text", operation: .contains, values: ["100%_real"])
        ])
        let compiled = try expression.compile(allowedColumns: ["age", "name"])
        #expect(compiled.sql.contains("\"age\" > $1::int4"))
        #expect(compiled.sql.contains("\"name\"::text ILIKE $2"))
        #expect(compiled.values == ["20", "%100\\%\\_real%"])
    }

    @Test func rejectsUnknownColumns() {
        let expression = FilterExpression.predicate(id: UUID(), column: "secret", typeName: "text", operation: .equal, values: ["x"])
        #expect(throws: FilterError.self) { try expression.compile(allowedColumns: ["public"]) }
    }
}
