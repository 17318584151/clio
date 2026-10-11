import CZstd
import Foundation

/// Decode all frames before parsing, so an incomplete or corrupt archive
/// cannot leave partially imported usage behind.
private enum Zstd {
    static func decode(_ data: Data) -> Data? {
        guard let stream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(stream) }
        var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        return data.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var decoded = Data()
            return buffer.withUnsafeMutableBytes { destination in
                while true {
                    var output = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let remaining = ZSTD_decompressStream(stream, &output, &input)
                    guard ZSTD_isError(remaining) == 0 else { return nil }
                    decoded.append(contentsOf: destination.prefix(output.pos))
                    if remaining == 0 && input.pos == input.size { return decoded }
                    if input.pos == input.size && output.pos < output.size { return nil }
                }
            }
        }
    }
}

/// Substring search over raw bytes.
///
/// The session logs are ~1 GiB of UTF-8. Decoding that into `String` and using
/// `String.contains` costs orders of magnitude more than the JSON parsing that
/// follows, because Swift's string comparison is grapheme-aware; `memmem` on
/// the bytes is what makes a full scan take seconds instead of minutes.
enum ByteSearch {
    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { pattern in
            memmem(base, haystack.count, pattern.baseAddress!, needle.count) != nil
        }
    }
}

/// Incremental reader over `.jsonl` logs and `.jsonl.zst` archives.
///
/// A full re-read of every session log is ~1 GiB on an active machine, so each
/// file is remembered by size and modification date and only the bytes appended
/// since the last pass are handed to the parser. A file that shrank was rotated
/// or rewritten and is read from the start again.
final class LogScanner {
    struct FileState {
        var size: Int
        var modified: Date
        var offset: Int
        var identity: AnyHashable?
    }

    /// Records older than this are never displayed (the heatmap covers 22
    /// weeks), so files untouched for longer are skipped entirely.
    static let retention: TimeInterval = 180 * 86400

    private let root: URL
    private var states: [String: FileState] = [:]

    init(root: URL) {
        self.root = root
    }

    var rootExists: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    /// Deleted or replaced files invalidate the readers' deduplication state.
    /// Rebuild from surviving files so a copied record can become the survivor.
    func needsRebuild() -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        return states.contains { path, previous in
            guard
                let values = try? URL(fileURLWithPath: path).resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]),
                let size = values.fileSize,
                let modified = values.contentModificationDate,
                modified > cutoff
            else { return true }
            if path.hasSuffix(".jsonl.zst"), size != previous.size || modified != previous.modified {
                return true
            }
            return size < previous.size
                || (size == previous.size && modified != previous.modified)
                || (values.fileResourceIdentifier as? AnyHashable) != previous.identity
        }
    }

    func reset() {
        states.removeAll()
    }

    /// Walk the tree and pass each newly appended line to `handle` as raw bytes,
    /// with the path of the file it came from.
    /// The buffer is only valid for the duration of the call.
    /// Returns the number of files that had new content.
    @discardableResult
    func scan(handle: (String, UnsafeRawBufferPointer) -> Void) -> Int {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
                ],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        let cutoff = Date().addingTimeInterval(-Self.retention)
        var touched = 0

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" || url.lastPathComponent.hasSuffix(".jsonl.zst") else {
                continue
            }
            guard
                let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
                ]),
                let size = values.fileSize,
                let modified = values.contentModificationDate,
                modified > cutoff
            else { continue }

            let key = url.path
            let previous = states[key]
            if let previous, previous.size == size, previous.modified == modified { continue }

            // A file smaller than last time was replaced, not appended to.
            let start = (previous.map { size < $0.size ? 0 : $0.offset }) ?? 0
            let consumed = read(url, from: start) { handle(key, $0) }
            states[key] = FileState(
                size: size, modified: modified, offset: consumed,
                identity: values.fileResourceIdentifier as? AnyHashable)
            touched += 1
        }
        return touched
    }

    /// Read from `offset` to EOF, emitting complete lines. Returns the offset of
    /// the last newline consumed so a half-written trailing line is re-read on
    /// the next pass instead of being parsed in two halves.
    private func read(_ url: URL, from offset: Int, handle: (UnsafeRawBufferPointer) -> Void) -> Int {
        // Mapped, not read into the heap: single session logs reach tens of
        // megabytes, and mapped pages are reclaimable under memory pressure.
        guard var data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return offset }
        if url.pathExtension == "zst" {
            guard let decoded = Zstd.decode(data) else { return offset }
            data = decoded
        }
        guard data.count > offset else { return offset }

        var consumed = offset
        data[offset...].withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var lineStart = 0
            while lineStart < raw.count {
                guard let newline = memchr(base + lineStart, 0x0A, raw.count - lineStart) else { break }
                let lineEnd = UnsafeRawPointer(newline) - base
                if lineEnd > lineStart {
                    // Each parsed line produces bridged Foundation objects; drain
                    // them per line or a full scan accumulates them all.
                    autoreleasepool {
                        handle(UnsafeRawBufferPointer(start: base + lineStart, count: lineEnd - lineStart))
                    }
                }
                consumed += lineEnd - lineStart + 1
                lineStart = lineEnd + 1
            }
        }
        return consumed
    }
}
