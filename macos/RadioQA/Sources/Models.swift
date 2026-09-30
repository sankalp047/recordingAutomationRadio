import Foundation

/// Mirrors the JSON from the show-archive API. See the integration notes.
struct StationsResponse: Codable {
    let timezone: String
    let window: Window
    let qaProfile: QAProfile
    let stations: [String]

    struct Window: Codable { let startHour: Int; let endHour: Int }
    struct QAProfile: Codable {
        let codec: String; let bitrateKbps: Int
        let channels: Int; let sampleRate: Int
    }
}

struct RecordingsResponse: Codable {
    let count: Int
    let truncated: Bool
    let recordings: [Recording]
}

struct Recording: Codable, Identifiable, Hashable {
    let id: String
    let station: String
    let date: String
    let startLocal: String
    let startISO: String
    let durationSeconds: Double
    let sizeBytes: Int
    let uploaded: String?
    let audioURL: String

    enum CodingKeys: String, CodingKey {
        case id, station, date, uploaded
        case startLocal = "start_local"
        case startISO = "start_iso"
        case durationSeconds = "duration_seconds"
        case sizeBytes = "size_bytes"
        case audioURL = "audio_url"
    }

    /// Hour of the broadcast day this segment starts in.
    var startHour: Int { Int(startLocal.prefix(2)) ?? 0 }

    var durationLabel: String {
        let m = Int(durationSeconds) / 60, s = Int(durationSeconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    /// A segment shorter than an hour means the recorder restarted mid-hour.
    /// Never assume 3600 - that is why duration is reported per object.
    var isPartial: Bool { durationSeconds < 3540 }
}

struct CoverageResponse: Codable {
    let date: String
    let complete: Bool
    let stations: [StationCoverage]
    let window: Window

    struct Window: Codable {
        let startHour: Int, endHour: Int
        let timezone: String
        enum CodingKeys: String, CodingKey {
            case startHour = "start_hour", endHour = "end_hour", timezone
        }
    }
}

struct StationCoverage: Codable, Identifiable, Hashable {
    let station: String
    let complete: Bool
    let hoursOK: Int
    let hoursTotal: Int
    let files: Int
    let gaps: [Gap]

    var id: String { station }

    enum CodingKeys: String, CodingKey {
        case station, complete, files, gaps
        case hoursOK = "hours_ok"
        case hoursTotal = "hours_total"
    }

    struct Gap: Codable, Hashable { let hour: Int; let coverage: Double }

    /// Coverage 0...1 for a given hour: a gap entry if present, else complete.
    func coverage(forHour h: Int) -> Double {
        gaps.first { $0.hour == h }?.coverage ?? 1.0
    }
}

extension StationsResponse {
    enum CodingKeys: String, CodingKey {
        case timezone, window, stations
        case qaProfile = "qa_profile"
    }
}
extension StationsResponse.Window {
    enum CodingKeys: String, CodingKey {
        case startHour = "start_hour", endHour = "end_hour"
    }
}
extension StationsResponse.QAProfile {
    enum CodingKeys: String, CodingKey {
        case codec, channels
        case bitrateKbps = "bitrate_kbps"
        case sampleRate = "sample_rate"
    }
}
