import Testing
@testable import Posty

struct SQLLexerTests {
    @Test func splitsOnlyAtExecutableSemicolons() {
        let sql = "SELECT ';' AS value; DO $$ BEGIN RAISE NOTICE ';'; END $$; SELECT 3"
        let statements = SQLLexer.statements(in: sql)
        #expect(statements.count == 3)
        #expect(statements[0].safety == .readOnly)
        #expect(statements[1].safety == .potentiallyWriting)
    }

    @Test func commentsDoNotChangeClassification() {
        #expect(SQLLexer.safety(of: "-- DELETE\nSELECT * FROM people") == .readOnly)
        #expect(SQLLexer.safety(of: "EXPLAIN ANALYZE UPDATE people SET name='x'") == .potentiallyWriting)
        #expect(SQLLexer.safety(of: "WITH changed AS (DELETE FROM people RETURNING *) SELECT * FROM changed") == .potentiallyWriting)
        #expect(SQLLexer.safety(of: "SELECT nextval('people_id_seq')") == .potentiallyWriting)
        #expect(SQLLexer.safety(of: "SELECT * INTO archived_people FROM people") == .potentiallyWriting)
    }

    @Test func detectsCatalogInvalidatingStatements() {
        #expect(SQLLexer.modifiesSchema("CREATE TABLE people(id bigint)"))
        #expect(SQLLexer.modifiesSchema("COMMENT ON TABLE people IS 'People'"))
        #expect(!SQLLexer.modifiesSchema("UPDATE people SET name = 'Ada'"))
    }
}
