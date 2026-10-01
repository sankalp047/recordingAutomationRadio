import Foundation
import Observation

enum Screen: String, CaseIterable, Identifiable {
    case find, status, health
    var id: String { rawValue }
    var title: String {
        switch self {
        case .find:   return "Find a recording"
        case .status: return "Status"
        case .health: return "History"
        }
    }
    var icon: String {
        switch self {
        case .find:   return "magnifyingglass"
        case .status: return "checkmark.seal"
        case .health: return "chart.bar"
        }
    }
    var blurb: String {
        switch self {
        case .find:   return "Listen or save any hour"
        case .status: return "Did everything record?"
        case .health: return "How it has been doing"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // settings
    var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") } }
    /// Not shown anywhere in the app. People are authenticated by Cloudflare
    /// Access; this only exists so a build can be pointed at an unprotected
    /// server during development.
    var token: String = ""
    var isConfigured: Bool { !baseURL.isEmpty }

    // navigation
    var screen: Screen = .find
    var focusedStation: String?

    // data
    var date = Date()
    var coverage: CoverageResponse?
    var recordings: [Recording] = []
    var stats: StatsResponse?
    var stations: [String] = ["sangam", "funasia", "vanakkam", "apnapunjab"]
    var startHour = 6
    var endHour = 24
    var historyDays = 14

    var loading = false
    var error: String?
    var needsSignIn = false
    var selected: Recording?

    private var client: APIClient { APIClient(baseURL: baseURL, token: token) }

    init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "https://radio-api.funasia.net"
        token = Keychain.get("apiToken") ?? ""
        if focusedStation == nil { focusedStation = stations.first }
    }

    func download(_ rec: Recording, to url: URL) async throws {
        try await client.download(rec, to: url)
    }

    var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f.string(from: date)
    }

    var friendlyDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: date)
    }

    var isToday: Bool { Calendar.current.isDateInToday(date) }

    func shiftDay(_ n: Int) {
        date = Calendar.current.date(byAdding: .day, value: n, to: date) ?? date
        Task { await load() }
    }

    func load() async {
        guard isConfigured else { error = APIError.notConfigured.errorDescription; return }
        loading = true
        error = nil
        needsSignIn = false
        defer { loading = false }
        let day = dateString
        do {
            async let cov = client.coverage(date: day)
            async let recs = client.recordings(date: day, station: nil)
            let (c, r) = try await (cov, recs)
            coverage = c
            recordings = r.recordings
            startHour = c.window.startHour
            endHour = c.window.endHour
            if !c.stations.isEmpty { stations = c.stations.map(\.station) }
        } catch let e as APIError {
            if case .needsSignIn = e { needsSignIn = true }
            error = e.errorDescription
            coverage = nil; recordings = []
        } catch {
            self.error = error.localizedDescription
            coverage = nil; recordings = []
        }
    }

    func loadStats() async {
        guard isConfigured else { return }
        do { stats = try await client.stats(days: historyDays) }
        catch let e as APIError {
            if case .needsSignIn = e { needsSignIn = true }
            error = e.errorDescription
        } catch { self.error = error.localizedDescription }
    }

    // MARK: derived

    func cov(_ station: String) -> StationCoverage? {
        coverage?.stations.first { $0.station == station }
    }

    /// Segments that BEGIN in this hour, in start order.
    ///
    /// Not segments overlapping the hour. Duration is derived from object size,
    /// so a full hour measures a fraction of a second over 3600 and would also
    /// "overlap" the next hour - which made one recording appear in two rows,
    /// highlight both as playing, and let an empty hour show a neighbour's
    /// duration beside its own "Not recorded". Coverage still uses real
    /// intervals; that is computed by the API and is unaffected.
    func segments(station: String, hour: Int) -> [Recording] {
        recordings.filter { $0.station == station && $0.startHour == hour }
            .sorted { $0.startLocal < $1.startLocal }
    }

    func recordings(for station: String) -> [Recording] {
        recordings.filter { $0.station == station }.sorted { $0.startLocal < $1.startLocal }
    }

    var stationsComplete: Int { coverage?.stations.filter(\.complete).count ?? 0 }
    var stationsTotal: Int { coverage?.stations.count ?? stations.count }
    var allComplete: Bool { coverage?.complete ?? false }

    /// Headline sentence. Deliberately plain English, no percentages.
    var headline: String {
        guard let c = coverage else { return "No information yet" }
        if isToday { return "Recording is in progress" }
        if c.complete { return "Everything recorded" }
        let bad = c.stations.filter { !$0.complete }
        if bad.count == 1 {
            return "\(StationName.pretty(bad[0].station)) has gaps"
        }
        return "\(bad.count) stations have gaps"
    }

    var subhead: String {
        guard let c = coverage else { return "" }
        let missing = c.stations.reduce(0) { $0 + ($1.hoursTotal - $1.hoursOK) }
        if isToday {
            let done = c.stations.reduce(0) { $0 + $1.hoursOK }
            return "\(done) complete \(done == 1 ? "hour" : "hours") recorded so far today."
        }
        if missing == 0 { return "All \(c.stations.count) stations recorded every hour from 6 AM to midnight." }
        return "\(missing) \(missing == 1 ? "hour is" : "hours are") missing or incomplete."
    }

    func playbackURL(for r: Recording) -> URL? { client.playbackURL(for: r) }

    var totalSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(recordings.reduce(0) { $0 + $1.sizeBytes }),
                                  countStyle: .file)
    }
}
