import SwiftUI
import Charts

/// BigFan analytics: totals, most-played content and the newest signups,
/// with a drill-down into any listener.
@MainActor
@Observable
final class BigfanAnalyticsModel {
    struct Ranked: Identifiable { let id: String; let name: String; let count: Int }
    struct User: Identifiable {
        let id: String
        let email: String
        let displayName: String
        let totalPoints: Int
        let isGuest: Bool
        let createdAt: String
        let lastLoginAt: String
        var shown: String { displayName.isEmpty ? email : displayName }
    }

    // @Observable requires one property per declaration
    var totalUsers = 0
    var newUsers7d = 0
    var newUsers30d = 0
    var pointsCurrent = 0
    var pointsLedger = 0
    var listeningHours = 0.0
    var topStations: [Ranked] = []
    var topPodcasts: [Ranked] = []
    var notes: [String] = []
    var users: [User] = []

    private(set) var loading = false
    var error: String?

    private let session: AdminSession
    init(session: AdminSession) { self.session = session }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            async let o = AdminAPI.call("GET", "api/admin/bigfan/analytics/overview", session: session)
            async let u = AdminAPI.call("GET", "api/admin/bigfan/analytics/users", session: session)
            let (ov, us) = try await (o, u)

            totalUsers = Int(ov["totalUsers"] as? Double ?? 0)
            newUsers7d = Int(ov["newUsers7d"] as? Double ?? 0)
            newUsers30d = Int(ov["newUsers30d"] as? Double ?? 0)
            pointsCurrent = Int(ov["totalPointsCurrent"] as? Double ?? 0)
            pointsLedger = Int(ov["totalPointsLedger"] as? Double ?? 0)
            listeningHours = ov["totalListeningHours"] as? Double ?? 0

            topStations = (ov["mostActiveStations"] as? [[String: Any]] ?? []).map {
                Ranked(id: $0["id"] as? String ?? UUID().uuidString,
                       name: $0["name"] as? String ?? "—",
                       count: Int($0["sessionCount"] as? Double ?? 0))
            }
            topPodcasts = (ov["mostActivePodcasts"] as? [[String: Any]] ?? []).map {
                Ranked(id: $0["id"] as? String ?? UUID().uuidString,
                       name: $0["title"] as? String ?? "—",
                       count: Int($0["sessionCount"] as? Double ?? 0))
            }
            notes = (ov["notes"] as? [String: Any] ?? [:]).values.compactMap { $0 as? String }

            users = (us["users"] as? [[String: Any]] ?? []).map {
                User(id: $0["id"] as? String ?? "",
                     email: $0["email"] as? String ?? "",
                     displayName: $0["displayName"] as? String ?? "",
                     totalPoints: Int($0["totalPoints"] as? Double ?? 0),
                     isGuest: $0["isGuest"] as? Bool ?? false,
                     createdAt: $0["createdAt"] as? String ?? "",
                     lastLoginAt: $0["lastLoginAt"] as? String ?? "")
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var newest: [User] {
        users.sorted { $0.createdAt > $1.createdAt }.prefix(10).map { $0 }
    }
}

struct BigfanAnalyticsScreen: View {
    let session: AdminSession
    @State private var model: BigfanAnalyticsModel
    @State private var showUsers = false
    @State private var openUser: BigfanAnalyticsModel.User?

    init(session: AdminSession) {
        self.session = session
        _model = State(initialValue: BigfanAnalyticsModel(session: session))
    }

    private let cols = [GridItem(.adaptive(minimum: 158), spacing: 12)]

    var body: some View {
        Group {
            if let e = model.error {
                EmptyState(symbol: "exclamationmark.triangle", title: "Could not load", message: e,
                           action: ("Try again", { Task { await model.load() } }))
            } else if model.loading && model.totalUsers == 0 {
                ProgressView("Loading analytics…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        LazyVGrid(columns: cols, spacing: 12) {
                            stat("Listeners", "\(model.totalUsers)")
                            stat("New this week", "\(model.newUsers7d)")
                            stat("New this month", "\(model.newUsers30d)")
                            stat("Points held", "\(model.pointsCurrent)")
                            stat("Points ever awarded", "\(model.pointsLedger)")
                            stat("Hours listened", String(format: "%.0f", model.listeningHours))
                        }

                        HStack(alignment: .top, spacing: 14) {
                            ranked("Most played stations", model.topStations)
                            ranked("Most played podcasts", model.topPodcasts)
                        }

                        HStack {
                            Text("Newest listeners").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button("See all \(model.users.count)") { showUsers = true }
                                .controlSize(.small)
                        }
                        VStack(spacing: 5) {
                            ForEach(model.newest) { u in userRow(u) }
                        }

                        ForEach(model.notes, id: \.self) { n in
                            Label(n, systemImage: "info.circle")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(22)
                }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showUsers) {
            BigfanUsersSheet(model: model) { u in showUsers = false; openUser = u }
        }
        .sheet(item: $openUser) { u in
            BigfanUserDetailSheet(session: session, user: u)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.16)))
    }

    private func ranked(_ title: String, _ rows: [BigfanAnalyticsModel.Ranked]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if rows.isEmpty {
                Text("No plays recorded.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Chart(rows) { r in
                    BarMark(x: .value("Sessions", r.count), y: .value("Name", r.name))
                        .foregroundStyle(Color.accentColor.gradient)
                }
                .chartXAxis { AxisMarks(position: .bottom) }
                .frame(height: CGFloat(max(rows.count, 1)) * 22 + 20)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.16)))
    }

    private func userRow(_ u: BigfanAnalyticsModel.User) -> some View {
        Button { openUser = u } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(u.shown).font(.system(size: 12, weight: .medium))
                        if u.isGuest {
                            Text("guest").font(.system(size: 9))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text(u.email).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(u.totalPoints) pts").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(CentralTime.displayDate(u.createdAt))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 78, alignment: .trailing)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

struct BigfanUsersSheet: View {
    let model: BigfanAnalyticsModel
    var onOpen: (BigfanAnalyticsModel.User) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var sort = "joined"

    private var rows: [BigfanAnalyticsModel.User] {
        var r = model.users
        if !search.isEmpty {
            r = r.filter { $0.email.localizedCaseInsensitiveContains(search)
                         || $0.displayName.localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case "name":   r.sort { $0.shown.localizedCaseInsensitiveCompare($1.shown) == .orderedAscending }
        case "points": r.sort { $0.totalPoints > $1.totalPoints }
        case "active": r.sort { $0.lastLoginAt > $1.lastLoginAt }
        default:       r.sort { $0.createdAt > $1.createdAt }
        }
        return r
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search name or email", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                Picker("", selection: $sort) {
                    Text("Joined").tag("joined")
                    Text("Name").tag("name")
                    Text("Points").tag("points")
                    Text("Last active").tag("active")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                Spacer()
                Text("\(rows.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Done") { dismiss() }
            }
            .padding(14)
            Divider()
            List(rows) { u in
                Button { onOpen(u) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(u.shown).font(.system(size: 12, weight: .medium))
                            Text(u.email).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(u.totalPoints) pts").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(width: 640, height: 620)
    }
}
