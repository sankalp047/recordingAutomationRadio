import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    // MARK: settings
    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    var token: String {
        didSet { Keychain.set(token, for: "apiToken") }
    }
    var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }

    // MARK: state
    var date = Date()
    var coverage: CoverageResponse?
    var recordings: [Recording] = []
    var stations: [String] = ["sangam", "funasia", "vanakkam", "apnapunjab"]
    var startHour = 6
    var endHour = 24

    var loading = false
    var error: String?
    var selected: Recording?

    private var client: APIClient { APIClient(baseURL: baseURL, token: token) }

    init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL")
            ?? "https://radio-api.funasia.net"
        token = Keychain.get("apiToken") ?? ""
    }

    var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        // The API works in broadcast days, which are America/Chicago dates.
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f.string(from: date)
    }

    func shiftDay(_ n: Int) {
        date = Calendar.current.date(byAdding: .day, value: n, to: date) ?? date
        Task { await load() }
    }

    func load() async {
        guard isConfigured else { error = APIError.notConfigured.errorDescription; return }
        loading = true
        error = nil
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
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            coverage = nil
            recordings = []
        }
    }

    func loadStations() async {
        guard isConfigured else { return }
        if let s = try? await client.stations() { stations = s.stations }
    }

    /// Segments overlapping a given station-hour, in start order.
    func segments(station: String, hour: Int) -> [Recording] {
        recordings.filter { r in
            guard r.station == station else { return false }
            let start = Double(r.startHour) * 3600
                + Double(Int(r.startLocal.dropFirst(3).prefix(2)) ?? 0) * 60
            let end = start + r.durationSeconds
            return start < Double(hour + 1) * 3600 && end > Double(hour) * 3600
        }
        .sorted { $0.startLocal < $1.startLocal }
    }

    func playbackURL(for r: Recording) -> URL? { client.playbackURL(for: r) }

    var totalSize: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(recordings.reduce(0) { $0 + $1.sizeBytes }),
            countStyle: .file)
    }
}
