import Foundation
import SQLite3

/// Builds conversations in the shape agy writes and checks what the reader takes from them.
@main
enum AntigravityReaderTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "clio-antigravity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date().timeIntervalSince1970.rounded()

        func usage(model: Int, input: Int, output: Int, cacheRead: Int = 0) -> [UInt8] {
            varint(1, model) + varint(2, input) + varint(3, output) + varint(5, cacheRead) + varint(9, output / 2)
        }
        func step(at seconds: Double, usage: [UInt8]?, generator: Int? = nil, execution: String? = nil) -> [UInt8] {
            var message = bytes(1, varint(1, Int(seconds)) + varint(2, 500_000_000))
            if let usage { message += bytes(9, usage) }
            if let generator { message += varint(11, generator) }
            if let execution { message += bytes(12, Array(execution.utf8)) }
            return message
        }
        func generator(model: Int, name: String?, execution: String, firstToken: Int = 0, streaming: Int = 0) -> [UInt8] {
            var chat = varint(3, model)
            if let name { chat += bytes(19, Array(name.utf8)) }
            chat += bytes(11, varint(1, firstToken)) + bytes(12, varint(1, streaming))
            return bytes(1, chat) + bytes(4, Array(execution.utf8))
        }

        let cli = root.appending(path: "antigravity-cli/conversations")
        let editor = root.appending(path: "antigravity/conversations")
        // A closed WAL database keeps neither its log nor shared memory.
        sqlite3_close(try write(cli.appending(path: "first.db"), wal: true, steps: [
            step(at: now - 60, usage: nil),
            step(at: now - 50, usage: usage(model: 1318, input: 100, output: 400, cacheRead: 1000), execution: "a"),
            step(at: now - 40, usage: usage(model: 1318, input: 0, output: 0)),
            // The step's own model field stands in when the usage omits it.
            step(at: now - 30, usage: varint(2, 7) + varint(3, 3), generator: 1532, execution: "b"),
        ], generators: [
            generator(model: 1318, name: "gemini-3.8-flash", execution: "a", firstToken: 2, streaming: 6),
            generator(model: 1318, name: "gemini-3.8-flash-n", execution: "x"),
            generator(model: 1532, name: nil, execution: "b"),
        ]))
        sqlite3_close(try write(editor.appending(path: "second.db"), wal: false, steps: [
            step(at: now - 20, usage: usage(model: 1532, input: 5, output: 5)),
            step(at: now - 10, usage: usage(model: 9999, input: 1, output: 1)),
        ], generators: [
            generator(model: 1318, name: "gemini-3.8-flash", execution: "c"),
            generator(model: 1532, name: "gemini-4-neon", execution: "d"),
        ]))
        // A running agy holds its conversation open with the newest steps still in the log.
        let live = try write(cli.appending(path: "live.db"), wal: true, steps: [
            step(at: now - 5, usage: usage(model: 1532, input: 2, output: 2)),
        ], generators: [])
        defer { sqlite3_close(live) }

        let reader = AntigravityReader(roots: [cli, editor, root.appending(path: "absent")])
        precondition(reader.isAvailable)
        let events = reader.refresh().sorted { $0.timestamp < $1.timestamp }
        precondition(events.count == 5, "steps without usage or tokens are skipped")
        let first = events[0]
        precondition(first.model == "gemini-3.8-flash", "the most frequent served id names a model enum")
        precondition(first.counts == TokenCounts(input: 100, output: 400, cacheRead: 1000))
        precondition(first.timestamp == Date(timeIntervalSince1970: now - 49.5))
        precondition(first.estimatedDuration == 8, "first-token wait and streaming come from the generator row")
        precondition(first.sessionID == "first" && first.source == .antigravity && first.category == .gemini)
        precondition(events[1].model == "gemini-4-neon" && events[1].counts.total == 10,
                     "the step's own model field stands in, named from another conversation")
        precondition(events[2].model == "gemini-4-neon" && events[2].sessionID == "second")
        precondition(events[3].model == "unknown")
        precondition(events[4].sessionID == "live", "steps not yet checkpointed are read from the log")
        precondition(Set(events.map(\.dedupeKey)).count == events.count)

        let revision = reader.revision
        _ = reader.refresh()
        precondition(reader.revision == revision, "unchanged conversations are not reread")
        try FileManager.default.removeItem(at: editor.appending(path: "second.db"))
        precondition(reader.refresh().count == 3 && reader.revision == revision + 1,
                     "a deleted conversation leaves the totals")
        print("Antigravity reader checks passed: steps, model names, timing, WAL and revisions")
    }

    /// Returns the open connection; the caller decides when the conversation closes.
    private static func write(_ path: URL, wal: Bool, steps: [[UInt8]], generators: [[UInt8]]) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        precondition(sqlite3_open(path.path, &handle) == SQLITE_OK)
        func run(_ sql: String, _ blob: [UInt8]? = nil, index: Int = 0) {
            var statement: OpaquePointer?
            precondition(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            if let blob {
                sqlite3_bind_int64(statement, 1, Int64(index))
                _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), nil) }
            }
            // The journal pragma answers with a row.
            precondition([SQLITE_DONE, SQLITE_ROW].contains(sqlite3_step(statement)))
        }
        if wal { run("PRAGMA journal_mode=WAL") }
        run("CREATE TABLE steps (idx integer PRIMARY KEY, metadata blob)")
        run("CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob)")
        for (index, step) in steps.enumerated() { run("INSERT INTO steps VALUES (?, ?)", step, index: index) }
        for (index, row) in generators.enumerated() { run("INSERT INTO gen_metadata VALUES (?, ?)", row, index: index) }
        return handle
    }

    private static func varint(_ field: Int, _ value: Int) -> [UInt8] {
        encode(field << 3) + encode(value)
    }

    private static func bytes(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        encode(field << 3 | 2) + encode(payload.count) + payload
    }

    private static func encode(_ value: Int) -> [UInt8] {
        var value = UInt64(value)
        var result: [UInt8] = []
        repeat {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            result.append(value == 0 ? byte : byte | 0x80)
        } while value != 0
        return result
    }
}
