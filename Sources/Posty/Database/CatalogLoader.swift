import Foundation
import PostgresNIO

enum CatalogLoader {
    static func load(using client: PostgresClient) async throws -> CatalogSnapshot {
        let identityRows = try await client.query("""
            SELECT current_setting('server_version_num')::int8 AS version_num,
                   version() AS version,
                   d.oid::int8 AS database_oid,
                   current_database() AS database_name
            FROM pg_database d WHERE d.datname = current_database()
            """).collect()
        guard let identity = identityRows.first else { throw DatabaseSessionError.catalogUnavailable }
        let versionNumber = Int(try decodeInt64(identity, "version_num"))
        guard (140000..<190000).contains(versionNumber) else {
            throw DatabaseSessionError.unsupportedServerVersion(versionNumber)
        }

        let typeRows = try await client.query("""
            SELECT t.oid::int8 AS oid, n.nspname AS schema_name, t.typname AS type_name,
                   t.typtype::text AS type_kind, t.typcategory::text AS category,
                   t.typelem::int8 AS element_oid, t.typbasetype::int8 AS base_oid,
                   COALESCE((SELECT json_agg(e.enumlabel ORDER BY e.enumsortorder)::text
                             FROM pg_enum e WHERE e.enumtypid = t.oid), '[]') AS enum_values
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname NOT LIKE 'pg_toast%'
            """).collect()
        var types: [UInt32: DatabaseTypeDescriptor] = [:]
        for row in typeRows {
            let oid = UInt32(try decodeInt64(row, "oid"))
            let typeKind = try decodeString(row, "type_kind")
            let category = try decodeString(row, "category")
            let enumData = Data((try decodeString(row, "enum_values")).utf8)
            let enumValues = (try? JSONDecoder().decode([String].self, from: enumData)) ?? []
            types[oid] = DatabaseTypeDescriptor(
                oid: oid,
                schema: try decodeString(row, "schema_name"),
                name: try decodeString(row, "type_name"),
                kind: typeDescriptorKind(typeKind: typeKind, category: category, oid: oid),
                category: category,
                elementOID: optionalOID(try decodeInt64(row, "element_oid")),
                baseTypeOID: optionalOID(try decodeInt64(row, "base_oid")),
                enumValues: enumValues
            )
        }
        // Domains use their base type's wire representation. Resolve that type here so
        // decoding and editors behave like the underlying PostgreSQL type.
        for _ in 0..<4 {
            for (oid, descriptor) in Array(types) {
                guard let baseOID = descriptor.baseTypeOID,
                      let base = types[baseOID],
                      descriptor.kind != base.kind else { continue }
                types[oid] = DatabaseTypeDescriptor(
                    oid: descriptor.oid,
                    schema: descriptor.schema,
                    name: descriptor.name,
                    kind: base.kind,
                    category: descriptor.category,
                    elementOID: descriptor.elementOID,
                    baseTypeOID: descriptor.baseTypeOID,
                    enumValues: descriptor.enumValues
                )
            }
        }

        let objectRows = try await client.query("""
            WITH db AS (SELECT oid FROM pg_database WHERE datname = current_database())
            SELECT db.oid::int8 AS database_oid, c.oid::int8 AS oid, n.nspname AS schema_name,
                   c.relname AS object_name,
                   CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitionedTable'
                     WHEN 'v' THEN 'view' WHEN 'm' THEN 'materializedView' WHEN 'S' THEN 'sequence' END AS kind,
                   obj_description(c.oid, 'pg_class') AS comment,
                   CASE WHEN c.relkind IN ('r','p','m') THEN c.reltuples::int8 ELSE NULL END AS estimated_rows,
                   CASE WHEN c.relkind IN ('r','p','m') THEN pg_total_relation_size(c.oid)::int8 ELSE NULL END AS total_bytes,
                   i.inhparent::int8 AS parent_oid
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN db
            LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
            WHERE c.relkind IN ('r','p','v','m','S') AND n.nspname NOT LIKE 'pg_toast%'
            UNION ALL
            SELECT db.oid::int8, p.oid::int8, n.nspname, p.proname,
                   CASE WHEN p.prokind = 'p' THEN 'procedure' ELSE 'function' END,
                   obj_description(p.oid, 'pg_proc'), NULL::int8, NULL::int8, NULL::int8
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace CROSS JOIN db
            WHERE n.nspname NOT LIKE 'pg_toast%'
            UNION ALL
            SELECT db.oid::int8, t.oid::int8, n.nspname, t.typname, 'type',
                   obj_description(t.oid, 'pg_type'), NULL::int8, NULL::int8, NULL::int8
            FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace CROSS JOIN db
            WHERE t.typtype IN ('e','d','c') AND n.nspname NOT LIKE 'pg_toast%'
            UNION ALL
            SELECT db.oid::int8, e.oid::int8, n.nspname, e.extname, 'extension',
                   obj_description(e.oid, 'pg_extension'), NULL::int8, NULL::int8, NULL::int8
            FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace CROSS JOIN db
            ORDER BY schema_name, object_name
            """).collect()

        let objects = try objectRows.map { row in
            CatalogObject(
                databaseOID: UInt32(try decodeInt64(row, "database_oid")),
                oid: UInt32(try decodeInt64(row, "oid")),
                schema: try decodeString(row, "schema_name"),
                name: try decodeString(row, "object_name"),
                kind: CatalogObjectKind(rawValue: try decodeString(row, "kind")) ?? .table,
                comment: decodeOptionalString(row, "comment"),
                estimatedRows: decodeOptionalInt64(row, "estimated_rows"),
                totalBytes: decodeOptionalInt64(row, "total_bytes"),
                parentOID: decodeOptionalInt64(row, "parent_oid").map(UInt32.init)
            )
        }

        // Column names and types are inexpensive enough to preload. This makes completion
        // useful immediately while constraints, indexes, policies and definitions stay lazy.
        let columnRows = try await client.query("""
            SELECT a.attrelid::int8 AS relation_oid, a.attnum::int8 AS attribute_number,
                   a.attname AS column_name, a.atttypid::int8 AS type_oid,
                   format_type(a.atttypid, a.atttypmod) AS formatted_type,
                   NOT a.attnotnull AS nullable,
                   pg_get_expr(ad.adbin, ad.adrelid) AS default_expression,
                   NULLIF(a.attidentity::text, '') AS identity_kind,
                   NULLIF(a.attgenerated::text, '') AS generated_kind,
                   col_description(a.attrelid, a.attnum) AS comment
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
            WHERE a.attnum > 0 AND NOT a.attisdropped
              AND c.relkind IN ('r','p','v','m') AND n.nspname NOT LIKE 'pg_toast%'
            ORDER BY a.attrelid, a.attnum
            """).collect()
        let catalogColumns = try columnRows.map { row in
            let oid = UInt32(try decodeInt64(row, "type_oid"))
            return CatalogColumn(
                relationOID: UInt32(try decodeInt64(row, "relation_oid")),
                attributeNumber: Int(try decodeInt64(row, "attribute_number")),
                name: try decodeString(row, "column_name"),
                typeOID: oid,
                formattedType: try decodeString(row, "formatted_type"),
                nullable: try row.makeRandomAccess()["nullable"].decode(Bool.self),
                defaultExpression: decodeOptionalString(row, "default_expression"),
                identity: decodeOptionalString(row, "identity_kind"),
                generated: decodeOptionalString(row, "generated_kind"),
                comment: decodeOptionalString(row, "comment"),
                enumValues: types[oid]?.enumValues ?? []
            )
        }
        return CatalogSnapshot(
            serverVersionNumber: versionNumber,
            serverVersion: try decodeString(identity, "version"),
            databaseOID: UInt32(try decodeInt64(identity, "database_oid")),
            databaseName: try decodeString(identity, "database_name"),
            objects: objects,
            columns: catalogColumns,
            types: types,
            loadedAt: .now
        )
    }

    static func relationDetails(for object: CatalogObject, using client: PostgresClient, types: [UInt32: DatabaseTypeDescriptor]) async throws -> RelationDetails {
        let columns = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT a.attnum::int8 AS attribute_number, a.attname AS column_name, a.atttypid::int8 AS type_oid,
                   format_type(a.atttypid, a.atttypmod) AS formatted_type, NOT a.attnotnull AS nullable,
                   pg_get_expr(ad.adbin, ad.adrelid) AS default_expression,
                   NULLIF(a.attidentity::text, '') AS identity_kind,
                   NULLIF(a.attgenerated::text, '') AS generated_kind,
                   col_description(a.attrelid, a.attnum) AS comment
            FROM pg_attribute a
            LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
            WHERE a.attrelid = \(object.oid) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """)).collect()
        let catalogColumns = try columns.map { row in
            let oid = UInt32(try decodeInt64(row, "type_oid"))
            return CatalogColumn(
                relationOID: object.oid,
                attributeNumber: Int(try decodeInt64(row, "attribute_number")),
                name: try decodeString(row, "column_name"),
                typeOID: oid,
                formattedType: try decodeString(row, "formatted_type"),
                nullable: try row.makeRandomAccess()["nullable"].decode(Bool.self),
                defaultExpression: decodeOptionalString(row, "default_expression"),
                identity: decodeOptionalString(row, "identity_kind"),
                generated: decodeOptionalString(row, "generated_kind"),
                comment: decodeOptionalString(row, "comment"),
                enumValues: types[oid]?.enumValues ?? []
            )
        }

        let constraintRows = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT con.oid::int8 AS oid, con.conname AS name, con.contype::text AS type,
                   pg_get_constraintdef(con.oid, true) AS definition,
                   COALESCE((SELECT json_agg(a.attname ORDER BY k.ordinality)::text
                             FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ordinality)
                             JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum), '[]') AS columns,
                   CASE WHEN con.confrelid = 0 THEN NULL ELSE con.confrelid::regclass::text END AS referenced_relation
            FROM pg_constraint con WHERE con.conrelid = \(object.oid) ORDER BY con.conname
            """)).collect()
        let constraints = try constraintRows.map { row in
            let data = Data((try decodeString(row, "columns")).utf8)
            return CatalogConstraint(
                oid: UInt32(try decodeInt64(row, "oid")),
                name: try decodeString(row, "name"),
                type: try decodeString(row, "type"),
                definition: try decodeString(row, "definition"),
                columns: (try? JSONDecoder().decode([String].self, from: data)) ?? [],
                referencedRelation: decodeOptionalString(row, "referenced_relation")
            )
        }

        let indexRows = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT i.indexrelid::int8 AS oid, ci.relname AS name, pg_get_indexdef(i.indexrelid) AS definition,
                   i.indisunique AS is_unique, i.indisprimary AS is_primary, i.indisvalid AS is_valid
            FROM pg_index i JOIN pg_class ci ON ci.oid = i.indexrelid
            WHERE i.indrelid = \(object.oid) ORDER BY ci.relname
            """)).collect()
        let indexes = try indexRows.map { row in
            CatalogIndex(
                oid: UInt32(try decodeInt64(row, "oid")),
                name: try decodeString(row, "name"),
                definition: try decodeString(row, "definition"),
                isUnique: try row.makeRandomAccess()["is_unique"].decode(Bool.self),
                isPrimary: try row.makeRandomAccess()["is_primary"].decode(Bool.self),
                isValid: try row.makeRandomAccess()["is_valid"].decode(Bool.self)
            )
        }

        let triggerRows = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT t.oid::int8 AS oid, t.tgname AS name, pg_get_triggerdef(t.oid, true) AS definition, t.tgenabled::text AS enabled
            FROM pg_trigger t WHERE t.tgrelid = \(object.oid) AND NOT t.tgisinternal ORDER BY t.tgname
            """)).collect()
        let triggers = try triggerRows.map { row in
            CatalogTrigger(
                oid: UInt32(try decodeInt64(row, "oid")),
                name: try decodeString(row, "name"),
                definition: try decodeString(row, "definition"),
                enabled: try decodeString(row, "enabled")
            )
        }

        let policyRows = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT pol.polname AS name, pol.polcmd::text AS command,
                   COALESCE((SELECT json_agg(r.rolname)::text FROM unnest(pol.polroles) role_oid JOIN pg_roles r ON r.oid = role_oid), '[]') AS roles,
                   pg_get_expr(pol.polqual, pol.polrelid) AS using_expression,
                   pg_get_expr(pol.polwithcheck, pol.polrelid) AS check_expression
            FROM pg_policy pol WHERE pol.polrelid = \(object.oid) ORDER BY pol.polname
            """)).collect()
        let policies = try policyRows.map { row in
            let data = Data((try decodeString(row, "roles")).utf8)
            return CatalogPolicy(
                name: try decodeString(row, "name"),
                command: try decodeString(row, "command"),
                roles: (try? JSONDecoder().decode([String].self, from: data)) ?? [],
                usingExpression: decodeOptionalString(row, "using_expression"),
                checkExpression: decodeOptionalString(row, "check_expression")
            )
        }

        var grantBinds = PostgresBindings(capacity: 2)
        grantBinds.append(object.schema)
        grantBinds.append(object.name)
        let grantRows = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT grantee, privilege_type, is_grantable
            FROM information_schema.role_table_grants
            WHERE table_schema = $1 AND table_name = $2
            ORDER BY grantee, privilege_type
            """, binds: grantBinds)).collect()
        let grants = try grantRows.map { row in
            CatalogGrant(
                grantee: try decodeString(row, "grantee"),
                privilege: try decodeString(row, "privilege_type"),
                isGrantable: (try decodeString(row, "is_grantable")) == "YES"
            )
        }

        let dependencyRows = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT 'uses' AS direction,
                   pg_describe_object(d.refclassid, d.refobjid, d.refobjsubid) AS object,
                   d.deptype::text AS kind
            FROM pg_depend d
            WHERE d.classid = 'pg_class'::regclass AND d.objid = \(object.oid)
            UNION ALL
            SELECT 'used by', pg_describe_object(d.classid, d.objid, d.objsubid), d.deptype::text
            FROM pg_depend d
            WHERE d.refclassid = 'pg_class'::regclass AND d.refobjid = \(object.oid)
            """)).collect()
        let dependencies = try dependencyRows.map { row in
            CatalogDependency(
                direction: try decodeString(row, "direction"),
                object: try decodeString(row, "object"),
                kind: try decodeString(row, "kind")
            )
        }

        var permissionBinds = PostgresBindings(capacity: 1)
        permissionBinds.append(Int64(object.oid))
        let permissionRow = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT has_table_privilege($1::oid, 'INSERT') AS can_insert,
                   has_table_privilege($1::oid, 'UPDATE') AS can_update,
                   has_table_privilege($1::oid, 'DELETE') AS can_delete
            """, binds: permissionBinds)).collect().first?.makeRandomAccess()

        return RelationDetails(
            object: object,
            columns: catalogColumns,
            constraints: constraints,
            indexes: indexes,
            triggers: triggers,
            policies: policies,
            grants: grants,
            dependencies: dependencies,
            canInsert: (try? permissionRow?["can_insert"].decode(Bool.self)) ?? false,
            canUpdate: (try? permissionRow?["can_update"].decode(Bool.self)) ?? false,
            canDelete: (try? permissionRow?["can_delete"].decode(Bool.self)) ?? false,
            definition: tableDDL(object: object, columns: catalogColumns, constraints: constraints, indexes: indexes, triggers: triggers)
        )
    }

    static func definition(for object: CatalogObject, using client: PostgresClient) async throws -> String {
        let sql: String
        switch object.kind {
        case .view, .materializedView:
            sql = "SELECT pg_get_viewdef(\(object.oid), true) AS definition"
        case .function, .procedure:
            sql = "SELECT pg_get_functiondef(\(object.oid)) AS definition"
        case .sequence:
            sql = "SELECT 'CREATE SEQUENCE ' || \(object.oid)::regclass::text AS definition"
        case .type:
            sql = "SELECT format_type(\(object.oid), NULL) AS definition"
        case .extensionObject:
            sql = "SELECT 'CREATE EXTENSION IF NOT EXISTS ' || quote_ident(extname) AS definition FROM pg_extension WHERE oid = \(object.oid)"
        case .table, .partitionedTable:
            return ""
        }
        return try decodeString(try await client.query(PostgresQuery(unsafeSQL: sql)).collect().first!, "definition")
    }

    private static func tableDDL(object: CatalogObject, columns: [CatalogColumn], constraints: [CatalogConstraint], indexes: [CatalogIndex], triggers: [CatalogTrigger]) -> String {
        var parts = columns.map { column in
            var definition = "    \(SQLIdentifier.quote(column.name)) \(column.formattedType)"
            if let generated = column.generated, generated == "s", let expression = column.defaultExpression {
                definition += " GENERATED ALWAYS AS (\(expression)) STORED"
            } else if let identity = column.identity {
                definition += identity == "a" ? " GENERATED ALWAYS AS IDENTITY" : " GENERATED BY DEFAULT AS IDENTITY"
            } else if let expression = column.defaultExpression {
                definition += " DEFAULT \(expression)"
            }
            if !column.nullable { definition += " NOT NULL" }
            return definition
        }
        parts += constraints.map { "    CONSTRAINT \(SQLIdentifier.quote($0.name)) \($0.definition)" }
        var ddl = "CREATE TABLE \(object.qualifiedName) (\n\(parts.joined(separator: ",\n"))\n);"
        let secondaryIndexes = indexes.filter { !$0.isPrimary }.map(\.definition)
        if !secondaryIndexes.isEmpty { ddl += "\n\n" + secondaryIndexes.joined(separator: ";\n") + ";" }
        if !triggers.isEmpty { ddl += "\n\n" + triggers.map(\.definition).joined(separator: ";\n") + ";" }
        return ddl
    }

    private static func typeDescriptorKind(typeKind: String, category: String, oid: UInt32) -> DatabaseTypeDescriptor.Kind {
        if typeKind == "e" { return .enumeration }
        if typeKind == "c" { return .composite }
        if category == "A" { return .array }
        if category == "R" { return .range }
        switch oid {
        case UInt32(PostgresDataType.bool.rawValue): return .boolean
        case UInt32(PostgresDataType.int2.rawValue), UInt32(PostgresDataType.int4.rawValue), UInt32(PostgresDataType.int8.rawValue): return .integer
        case UInt32(PostgresDataType.numeric.rawValue): return .numeric
        case UInt32(PostgresDataType.float4.rawValue), UInt32(PostgresDataType.float8.rawValue): return .floating
        case UInt32(PostgresDataType.uuid.rawValue): return .uuid
        case UInt32(PostgresDataType.bytea.rawValue): return .binary
        case UInt32(PostgresDataType.json.rawValue), UInt32(PostgresDataType.jsonb.rawValue): return .json
        case UInt32(PostgresDataType.date.rawValue): return .date
        case UInt32(PostgresDataType.time.rawValue), UInt32(PostgresDataType.timetz.rawValue): return .time
        case UInt32(PostgresDataType.timestamp.rawValue), UInt32(PostgresDataType.timestamptz.rawValue): return .timestamp
        case UInt32(PostgresDataType.interval.rawValue): return .interval
        default: return category == "S" ? .text : .unknown
        }
    }

    private static func optionalOID(_ value: Int64) -> UInt32? { value == 0 ? nil : UInt32(value) }

    static func decodeString(_ row: PostgresRow, _ name: String) throws -> String { try row.makeRandomAccess()[name].decode(String.self) }
    static func decodeInt64(_ row: PostgresRow, _ name: String) throws -> Int64 { try row.makeRandomAccess()[name].decode(Int64.self) }
    static func decodeOptionalString(_ row: PostgresRow, _ name: String) -> String? { try? row.makeRandomAccess()[name].decode(String?.self) }
    static func decodeOptionalInt64(_ row: PostgresRow, _ name: String) -> Int64? { try? row.makeRandomAccess()[name].decode(Int64?.self) }
}
