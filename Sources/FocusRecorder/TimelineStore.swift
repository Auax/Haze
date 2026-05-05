import Foundation

enum TimelineStore {
    static func save(_ session: RecordingSession) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: session.timelineURL, options: .atomic)
    }

    static func load(from url: URL) throws -> RecordingSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingSession.self, from: Data(contentsOf: url))
    }
}
