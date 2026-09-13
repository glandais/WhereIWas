import Compression
import Foundation

/// Writes an export to a file, gzipping it on the way when asked.
///
/// The audit trail is the one export that is genuinely large — a ride with
/// accepted fixes and filter checks on fills 25 MB in a week — and it is text,
/// so it deflates by about ten to one. Compressing while writing rather than
/// afterwards means the uncompressed file never exists: nothing on disk, and
/// nothing held in memory beyond one page.
///
/// `Compression`'s `COMPRESSION_ZLIB` is raw DEFLATE, not a container, so the
/// gzip framing is written here: the ten-byte header, then the deflate stream,
/// then CRC-32 and the input size, both little-endian. That is what makes the
/// result something `gunzip`, Finder and every `.gz` reader open — a bare
/// deflate stream is not.
///
/// Not `Sendable` on purpose: it owns a `FileHandle` and a compression stream,
/// and it is used inside one actor-isolated call.
final class AuditFileWriter {
    private let handle: FileHandle
    private let compressed: Bool
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!,
                                            dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!,
                                            src_size: 0,
                                            state: nil)
    private var streamOpen = false
    private let bufferSize = 64 * 1024
    private let buffer: UnsafeMutablePointer<UInt8>
    /// Running CRC-32 of the *uncompressed* bytes, pre-final-inversion.
    private var crc: UInt32 = 0xFFFF_FFFF
    /// Uncompressed size, modulo 2³² as the gzip trailer defines it.
    private var size: UInt32 = 0
    private var finished = false

    init(url: URL, compressed: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = try FileHandle(forWritingTo: url)
        self.compressed = compressed
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

        guard compressed else { return }
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            buffer.deallocate()
            try? handle.close()
            throw CocoaError(.fileWriteUnknown)
        }
        streamOpen = true
        // Magic, deflate, no flags, no mtime, no extra flags, unknown OS.
        try handle.write(contentsOf: Data([0x1F, 0x8B, 0x08, 0x00,
                                           0x00, 0x00, 0x00, 0x00,
                                           0x00, 0xFF]))
    }

    deinit {
        if streamOpen { compression_stream_destroy(&stream) }
        buffer.deallocate()
        try? handle.close()
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        guard compressed else {
            try handle.write(contentsOf: data)
            return
        }
        crc = Self.crc32(crc, data)
        size = size &+ UInt32(truncatingIfNeeded: data.count)
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base
            stream.src_size = raw.count
            try drain(flags: 0)
        }
    }

    /// Flushes the stream, writes the gzip trailer and closes the file.
    /// Idempotent, so a `defer` can call it after an explicit one.
    func finish() throws {
        guard !finished else { return }
        finished = true
        if compressed {
            stream.src_ptr = UnsafePointer<UInt8>(bitPattern: -1)!
            stream.src_size = 0
            try drain(flags: Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            var trailer = Data()
            for value in [crc ^ 0xFFFF_FFFF, size] {
                withUnsafeBytes(of: value.littleEndian) { trailer.append(contentsOf: $0) }
            }
            try handle.write(contentsOf: trailer)
        }
        try handle.close()
    }

    /// Runs the encoder until it has consumed the source, writing whatever it
    /// produced. `FINALIZE` is passed only on the last call, and then the loop
    /// runs to `END` rather than to an empty source: the encoder still has a
    /// block to flush after the last byte went in.
    private func drain(flags: Int32) throws {
        let finalizing = flags != 0
        while true {
            stream.dst_ptr = buffer
            stream.dst_size = bufferSize
            let status = compression_stream_process(&stream, flags)
            guard status != COMPRESSION_STATUS_ERROR else { throw CocoaError(.fileWriteUnknown) }
            let produced = bufferSize - stream.dst_size
            if produced > 0 {
                try handle.write(contentsOf: Data(bytes: buffer, count: produced))
            }
            if status == COMPRESSION_STATUS_END { return }
            if !finalizing && stream.src_size == 0 && stream.dst_size > 0 { return }
        }
    }

    // MARK: CRC-32

    /// The standard (reflected, polynomial `0xEDB88320`) table gzip uses.
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    private static func crc32(_ start: UInt32, _ data: Data) -> UInt32 {
        var crc = start
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
        }
        return crc
    }
}
