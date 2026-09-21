import Testing
@testable import Posty

struct DatabaseValueTests {
    @Test func gridFormatsDatesForPeople() {
        let date = DatabaseValue.date("2026-08-27")
        let timestamp = DatabaseValue.timestamp("2026-08-27T12:34:56.123456Z")

        #expect(date.gridDisplayString != date.displayString)
        #expect(date.gridDisplayString.contains("2026"))
        #expect(timestamp.gridDisplayString != timestamp.displayString)
        #expect(timestamp.gridDisplayString.contains("2026"))
    }

    @Test func gridCompactsJSONWithoutChangingItsMeaning() throws {
        let value = DatabaseValue.json("{\n  \"enabled\": true,\n  \"count\": 3\n}")
        #expect(value.gridDisplayString == #"{"count":3,"enabled":true}"#)
    }
}
