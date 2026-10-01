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

// MARK: - /stats

struct StatsResponse: Codable {
    let from: String
    let to: String
    let days: Int
    let stations: [StationStats]
}

struct StationStats: Codable, Identifiable, Hashable {
    let station: String
    let days: [DayStat]
    let summary: Summary
    var id: String { station }

    struct DayStat: Codable, Hashable, Identifiable {
        let date: String
        let complete: Bool
        let hoursOK: Int
        let hoursTotal: Int
        let files: Int
        let restarts: Int
        let recordedSeconds: Int
        let bytes: Int
        let gaps: [Int]

        var id: String { date }
        var fraction: Double { hoursTotal == 0 ? 0 : Double(hoursOK) / Double(hoursTotal) }
        var hasData: Bool { files > 0 }

        enum CodingKeys: String, CodingKey {
            case date, complete, files, restarts, gaps, bytes
            case hoursOK = "hours_ok"
            case hoursTotal = "hours_total"
            case recordedSeconds = "recorded_seconds"
        }
    }

    struct Summary: Codable, Hashable {
        let daysCounted: Int
        let daysComplete: Int
        let totalHoursOK: Int
        let totalHoursExpected: Int
        let totalFiles: Int
        let totalRestarts: Int
        let totalBytes: Int
        let reliability: Double

        enum CodingKeys: String, CodingKey {
            case reliability
            case daysCounted = "days_counted"
            case daysComplete = "days_complete"
            case totalHoursOK = "total_hours_ok"
            case totalHoursExpected = "total_hours_expected"
            case totalFiles = "total_files"
            case totalRestarts = "total_restarts"
            case totalBytes = "total_bytes"
        }
    }
}

/// Plain-language station names. The API uses short ids; people do not.
enum StationName {
    private static let map = [
        "sangam": "Radio Sangam",
        "funasia": "FunAsia",
        "vanakkam": "Vanakkam FM",
        "apnapunjab": "Apna Punjab",
    ]
    static func pretty(_ id: String) -> String { map[id] ?? id.capitalized }
}

/// "6 AM" reads better than "06" for people who are not engineers.
enum HourLabel {
    static func short(_ h: Int) -> String {
        let hour = h % 24
        if hour == 0 { return "12 AM" }
        if hour == 12 { return "12 PM" }
        return hour < 12 ? "\(hour) AM" : "\(hour - 12) PM"
    }
    static func compact(_ h: Int) -> String {
        let hour = h % 24
        if hour == 0 { return "12a" }
        if hour == 12 { return "12p" }
        return hour < 12 ? "\(hour)a" : "\(hour - 12)p"
    }
}


struct Me: Codable {
    let signedIn: Bool
    let kind: String
    let email: String?
    let name: String?

    var display: String { email ?? name ?? "signed in" }
    var isPerson: Bool { kind == "user" }

    enum CodingKeys: String, CodingKey {
        case kind, email, name
        case signedIn = "signed_in"
    }
}
