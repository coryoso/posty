import Foundation
import PostgresNIO

enum DatabaseValueDecoder {
    static func decode(_ cell: PostgresCell, types: [UInt32: DatabaseTypeDescriptor]) -> DatabaseValue {
        guard cell.bytes != nil else { return .null }
        let oid = UInt32(cell.dataType.rawValue)
        let descriptor = types[oid]
        if let baseOID = descriptor?.baseTypeOID, let bytes = cell.bytes {
            let baseCell = PostgresCell(
                bytes: bytes,
                dataType: PostgresDataType(baseOID),
                format: cell.format,
                columnName: cell.columnName,
                columnIndex: cell.columnIndex
            )
            return decode(baseCell, types: types)
        }
        let kind = descriptor?.kind ?? builtInKind(oid: oid)

        do {
            switch kind {
            case .boolean:
                return .boolean(try cell.decode(Bool.self))
            case .integer:
                if oid == UInt32(PostgresDataType.int2.rawValue) { return .integer(Int64(try cell.decode(Int16.self))) }
                if oid == UInt32(PostgresDataType.int4.rawValue) { return .integer(Int64(try cell.decode(Int32.self))) }
                return .integer(try cell.decode(Int64.self))
            case .numeric:
                return .numeric(NSDecimalNumber(decimal: try cell.decode(Decimal.self)).stringValue)
            case .floating:
                if oid == UInt32(PostgresDataType.float4.rawValue) { return .floating(Double(try cell.decode(Float.self))) }
                return .floating(try cell.decode(Double.self))
            case .uuid:
                return .uuid(try cell.decode(UUID.self))
            case .json:
                return .json(try cell.decode(String.self))
            case .date:
                return .date(formatDate(try cell.decode(Date.self), dateOnly: true))
            case .timestamp:
                return .timestamp(formatDate(try cell.decode(Date.self), dateOnly: false))
            case .time:
                return .time(decodeTime(cell) ?? rawString(cell) ?? "")
            case .interval:
                return .interval(decodeInterval(cell) ?? rawString(cell) ?? "")
            case .binary:
                return .binary(data(cell))
            case .enumeration:
                return .enumeration(try cell.decode(String.self))
            case .array:
                return decodeArray(cell, descriptor: descriptor, types: types)
            case .range:
                return .range(rawString(cell) ?? hex(cell))
            case .text, .composite:
                return .string(try cell.decode(String.self))
            case .unknown:
                let raw = data(cell)
                if let string = String(data: raw, encoding: .utf8), string.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
                }) {
                    return .fallback(typeName: descriptor?.qualifiedName ?? "oid:\(oid)", display: string, raw: raw)
                }
                return .fallback(typeName: descriptor?.qualifiedName ?? "oid:\(oid)", display: "0x" + raw.map { String(format: "%02x", $0) }.joined(), raw: raw)
            }
        } catch {
            let raw = data(cell)
            return .fallback(typeName: descriptor?.qualifiedName ?? "oid:\(oid)", display: rawString(cell) ?? "0x" + raw.map { String(format: "%02x", $0) }.joined(), raw: raw)
        }
    }

    private static func decodeArray(_ cell: PostgresCell, descriptor: DatabaseTypeDescriptor?, types: [UInt32: DatabaseTypeDescriptor]) -> DatabaseValue {
        guard var buffer = cell.bytes,
              let dimensions = buffer.readInteger(as: Int32.self), dimensions >= 0,
              buffer.readInteger(as: Int32.self) != nil,
              let elementOID = buffer.readInteger(as: UInt32.self) else {
            return .fallback(typeName: descriptor?.qualifiedName ?? "array", display: hex(cell), raw: data(cell))
        }
        var count = 1
        for _ in 0..<dimensions {
            guard let length = buffer.readInteger(as: Int32.self), buffer.readInteger(as: Int32.self) != nil else {
                return .fallback(typeName: descriptor?.qualifiedName ?? "array", display: hex(cell), raw: data(cell))
            }
            count *= max(0, Int(length))
        }
        var values: [DatabaseValue] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            guard let length = buffer.readInteger(as: Int32.self) else { break }
            if length == -1 {
                values.append(.null)
            } else if let bytes = buffer.readSlice(length: Int(length)) {
                let nested = PostgresCell(
                    bytes: bytes,
                    dataType: PostgresDataType(elementOID),
                    format: .binary,
                    columnName: "[\(index)]",
                    columnIndex: index
                )
                values.append(decode(nested, types: types))
            }
        }
        return .array(values)
    }

    private static func decodeTime(_ cell: PostgresCell) -> String? {
        guard var buffer = cell.bytes, let microseconds = buffer.readInteger(as: Int64.self) else { return nil }
        let totalSeconds = microseconds / 1_000_000
        let fraction = abs(microseconds % 1_000_000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld:%02lld.%06lld", hours, minutes, seconds, fraction)
    }

    private static func decodeInterval(_ cell: PostgresCell) -> String? {
        guard var buffer = cell.bytes,
              let microseconds = buffer.readInteger(as: Int64.self),
              let days = buffer.readInteger(as: Int32.self),
              let months = buffer.readInteger(as: Int32.self) else { return nil }
        let seconds = Double(microseconds) / 1_000_000
        return "\(months) mons \(days) days \(seconds) seconds"
    }

    private static func formatDate(_ date: Date, dateOnly: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = dateOnly ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return formatter.string(from: date)
    }

    private static func rawString(_ cell: PostgresCell) -> String? {
        try? cell.decode(String.self)
    }

    private static func data(_ cell: PostgresCell) -> Data {
        guard var buffer = cell.bytes else { return Data() }
        return buffer.readData(length: buffer.readableBytes) ?? Data()
    }

    private static func hex(_ cell: PostgresCell) -> String {
        data(cell).map { String(format: "%02x", $0) }.joined()
    }

    private static func builtInKind(oid: UInt32) -> DatabaseTypeDescriptor.Kind {
        switch oid {
        case UInt32(PostgresDataType.bool.rawValue): .boolean
        case UInt32(PostgresDataType.int2.rawValue), UInt32(PostgresDataType.int4.rawValue), UInt32(PostgresDataType.int8.rawValue): .integer
        case UInt32(PostgresDataType.numeric.rawValue): .numeric
        case UInt32(PostgresDataType.float4.rawValue), UInt32(PostgresDataType.float8.rawValue): .floating
        case UInt32(PostgresDataType.uuid.rawValue): .uuid
        case UInt32(PostgresDataType.bytea.rawValue): .binary
        case UInt32(PostgresDataType.json.rawValue), UInt32(PostgresDataType.jsonb.rawValue): .json
        case UInt32(PostgresDataType.date.rawValue): .date
        case UInt32(PostgresDataType.time.rawValue), UInt32(PostgresDataType.timetz.rawValue): .time
        case UInt32(PostgresDataType.timestamp.rawValue), UInt32(PostgresDataType.timestamptz.rawValue): .timestamp
        case UInt32(PostgresDataType.interval.rawValue): .interval
        case UInt32(PostgresDataType.text.rawValue), UInt32(PostgresDataType.varchar.rawValue), UInt32(PostgresDataType.bpchar.rawValue), UInt32(PostgresDataType.name.rawValue): .text
        default: .unknown
        }
    }
}
