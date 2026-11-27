import Foundation
import SQLite3

/// Reads Antigravity conversations: `~/.gemini/antigravity-cli` for agy and
/// `~/.gemini/antigravity` for the editor.
///
/// Each conversation is a SQLite database. A step's `metadata` is a
/// `cortex_pb.CortexStepMetadata` message, and steps that called a model carry
/// `model_usage` (`codeium_common_pb.ModelUsageStats`): input excludes cache
/// reads, output includes thinking. Steps name the model only by enum, which
/// the usage itself carries and the step's `generator_model` repeats.
/// `gen_metadata` rows (`CortexStepGeneratorMetadata`) pair that enum with the
/// served model id and the call's timing. Serving variants share an enum, so
/// the id seen most often across conversations names it.
final class AntigravityReader {
    private struct Call {
        let index: Int
        let timestamp: Date
        let model: Int?
        let counts: TokenCounts
        let duration: TimeInterval?
    }

    private struct Conversation {
        let id: String
        let stamp: [Double]
        let calls: [Call]
        let models: [Int: [String: Int]]
    }

    private(set) var revision = 0
    private let roots: [URL]
    private var conversations: [String: Conversation] = [:]

    init(roots: [URL] = AntigravityReader.defaultRoots) {
        self.roots = roots
    }

    static var defaultRoots: [URL] {
        let gemini = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini")
        return ["antigravity-cli", "antigravity"].map { gemini.appending(path: "\($0)/conversations") }
    }

    var isAvailable: Bool {
        roots.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Rereads only conversations whose database or write-ahead log changed.
    func refresh() -> [UsageEvent] {
        let cutoff = Date().addingTimeInterval(-LogScanner.retention).timeIntervalSince1970
        var seen: Set<String> = []
        var changed = false
        for root in roots {
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "db" {
                let stamp = Self.stamp(file)
                guard stride(from: 1, to: stamp.count, by: 2).contains(where: { stamp[$0] > cutoff }) else { continue }
                seen.insert(file.path)
                guard conversations[file.path]?.stamp != stamp,
                      let reading = Self.read(file, stamp: stamp) else { continue }
                conversations[file.path] = reading
                changed = true
            }
        }
        let stale = conversations.keys.filter { !seen.contains($0) }
        stale.forEach { conversations[$0] = nil }
        if changed || !stale.isEmpty { revision += 1 }

        var votes: [Int: [String: Int]] = [:]
        for conversation in conversations.values {
            for (model, names) in conversation.models {
                votes[model, default: [:]].merge(names, uniquingKeysWith: +)
            }
        }
        let names = votes.compactMapValues { counts in
            counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        return conversations.values.flatMap { conversation in
            conversation.calls.map { call in
                UsageEvent(timestamp: call.timestamp,
                           model: call.model.flatMap { names[$0] } ?? "unknown",
                           counts: call.counts,
                           dedupeKey: "antigravity:\(conversation.id):\(call.index)",
                           sessionID: conversation.id,
                           estimatedDuration: call.duration,
                           source: .antigravity)
            }
        }
    }

    /// Size and modification time of the database and of its write-ahead log.
    private static func stamp(_ file: URL) -> [Double] {
        [file, URL(fileURLWithPath: file.path + "-wal")].flatMap { url -> [Double] in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return [] }
            return [Double(size), modified.timeIntervalSince1970]
        }
    }

    /// A read-only connection needs the shared-memory file a running agy keeps;
    /// a closed conversation has none and is read as immutable instead.
    private static func read(_ file: URL, stamp: [Double]) -> Conversation? {
        for options in ["mode=ro", "immutable=1"] {
            var handle: OpaquePointer?
            defer { sqlite3_close(handle) }
            guard sqlite3_open_v2(file.absoluteString + "?" + options, &handle,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { continue }
            var models: [Int: [String: Int]] = [:]
            var durations: [String: TimeInterval] = [:]
            // Older conversations may lack generator rows; their calls stay unnamed.
            _ = rows(handle, "SELECT data FROM gen_metadata") { statement in
                let row = blob(statement, 0)
                guard let chat = row.message(1) else { return }
                if let model = chat.varint(3), let name = chat.string(19), !name.isEmpty {
                    models[Int(model), default: [:]][name, default: 0] += 1
                }
                let parts = [chat.message(11), chat.message(12)].compactMap { $0?.seconds }
                if let execution = row.string(4), !parts.isEmpty {
                    durations[execution] = parts.reduce(0, +)
                }
            }
            var calls: [Call] = []
            let complete = rows(handle, "SELECT idx, metadata FROM steps") { statement in
                let metadata = blob(statement, 1)
                guard let usage = metadata.message(9), let created = metadata.message(1)?.seconds else { return }
                let counts = TokenCounts(input: usage.int(2), output: usage.int(3), cacheRead: usage.int(5),
                                         cacheWrite5m: usage.int(4))
                guard counts.total > 0 else { return }
                calls.append(Call(index: Int(sqlite3_column_int64(statement, 0)),
                                  timestamp: Date(timeIntervalSince1970: created),
                                  model: (usage.varint(1) ?? metadata.varint(11)).map(Int.init),
                                  counts: counts,
                                  duration: metadata.string(12).flatMap { durations[$0] }))
            }
            guard complete else { continue }
            return Conversation(id: file.deletingPathExtension().lastPathComponent, stamp: stamp,
                                calls: calls, models: models)
        }
        return nil
    }

    private static func rows(_ handle: OpaquePointer?, _ sql: String, _ body: (OpaquePointer) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: body(statement)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Protobuf {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Protobuf([]) }
        return Protobuf(Array(UnsafeRawBufferPointer(start: bytes, count: count)))
    }
}

/// Just enough of the protobuf wire format to pick known fields out of a message.
struct Protobuf {
    private enum Value {
        case varint(UInt64)
        case bytes(Range<Int>)
    }

    private let bytes: [UInt8]
    private let range: Range<Int>

    init(_ bytes: [UInt8]) {
        self.init(bytes, bytes.indices)
    }

    private init(_ bytes: [UInt8], _ range: Range<Int>) {
        self.bytes = bytes
        self.range = range
    }

    func varint(_ field: Int) -> UInt64? {
        guard case .varint(let value)? = first(field) else { return nil }
        return value
    }

    func int(_ field: Int) -> Int {
        varint(field).map { Int(clamping: $0) } ?? 0
    }

    func message(_ field: Int) -> Protobuf? {
        guard case .bytes(let range)? = first(field) else { return nil }
        return Protobuf(bytes, range)
    }

    func string(_ field: Int) -> String? {
        guard case .bytes(let range)? = first(field) else { return nil }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    /// `google.protobuf.Timestamp` and `Duration` share this layout.
    var seconds: TimeInterval {
        Double(Int64(bitPattern: varint(1) ?? 0)) + Double(Int64(bitPattern: varint(2) ?? 0)) / 1e9
    }

    private func first(_ field: Int) -> Value? {
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard let key = read(&offset) else { return nil }
            switch key & 7 {
            case 0:
                guard let value = read(&offset) else { return nil }
                if key >> 3 == field { return .varint(value) }
            case 1: offset += 8
            case 5: offset += 4
            case 2:
                guard let length = read(&offset), length <= UInt64(range.upperBound - offset) else { return nil }
                let end = offset + Int(length)
                if key >> 3 == field { return .bytes(offset..<end) }
                offset = end
            default: return nil
            }
        }
        return nil
    }

    private func read(_ offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while offset < range.upperBound, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
        return nil
    }
}
