import Foundation

/// JSON export: an envelope with a `samples` array of ``StoredLocationSample``
/// (the same shape a future upload layer would send), ISO-8601 dates.
enum JSONExporter {
    struct Envelope: Codable, Sendable, Hashable {
        var format: String = "whereiwas.samples"
        var version: Int = 1
        var exportedAt: Date
        var sampleCount: Int
        var samples: [StoredLocationSample]
    }

    static func export(_ samples: [StoredLocationSample], exportedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let envelope = Envelope(exportedAt: exportedAt, sampleCount: samples.count, samples: samples)
        return try encoder.encode(envelope)
    }

    /// Parses a document produced by ``export(_:exportedAt:)`` (round-trip for tests / import).
    static func decode(_ data: Data) throws -> Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope.self, from: data)
    }

    /// Writes the JSON document to `directory` (default: temporary directory)
    /// and returns the file URL, ready for `ShareLink`.
    static func write(_ samples: [StoredLocationSample],
                      name: String,
                      to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent(ExportFileName.make(name: name, format: .json))
        try export(samples).write(to: url, options: .atomic)
        return url
    }
}
