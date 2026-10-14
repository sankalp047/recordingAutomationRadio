import SwiftUI
import Charts

/// One listener: when they listen, what they played, points and redemptions.
struct BigfanUserDetailSheet: View {
    let session: AdminSession
    let user: BigfanAnalyticsModel.User
    @Environment(\.dismiss) private var dismiss

    @State private var hourBuckets: [Int] = []
    @State private var dayBuckets: [Int] = []
    @State private var totalHours = 0.0
    @State private var sessionCount = 0
    @State private var ledger: [[String: Any]] = []
    @State private var balance = 0
    @State private var codes: [[String: Any]] = []
    @State private var claims: [[String: Any]] = []
    @State private var location: String?
    @State private var loading = true
    @State private var error: String?

    private let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(user.shown).font(.system(size: 15, weight: .semibold))
                    Text(user.email).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()

            if let e = error {
                EmptyState(symbol: "exclamationmark.triangle", title: "Could not load", message: e)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            stat("Points now", "\(balance)")
                            stat("Hours listened", String(format: "%.1f", totalHours))
                            stat("Sessions", "\(sessionCount)")
                            stat("Joined", CentralTime.displayDate(user.createdAt))
                        }
                        if let l = location, !l.isEmpty {
                            Label(l, systemImage: "location").font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        if hourBuckets.contains(where: { $0 > 0 }) {
                            section("When they listen") {
                                Chart(Array(hourBuckets.enumerated()), id: \.offset) { i, v in
                                    BarMark(x: .value("Hour", i), y: .value("Sessions", v))
                                        .foregroundStyle(Color.accentColor.gradient)
                                }
                                .chartXAxis {
                                    AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                                        AxisValueLabel {
                                            if let h = v.as(Int.self) { Text(HourLabel.compact(h)) }
                                        }
                                    }
                                }
                                .frame(height: 110)
                            }
                        }

                        if dayBuckets.contains(where: { $0 > 0 }) {
                            section("Which days") {
                                Chart(Array(dayBuckets.enumerated()), id: \.offset) { i, v in
                                    BarMark(x: .value("Day", days[min(i, 6)]), y: .value("Sessions", v))
                                        .foregroundStyle(Color.accentColor.gradient)
                                }
                                .frame(height: 110)
                            }
                        }

                        if !ledger.isEmpty {
                            section("Points history") {
                                VStack(spacing: 4) {
                                    ForEach(Array(ledger.prefix(15).enumerated()), id: \.offset) { _, e in
                                        HStack {
                                            Text(e["reason"] as? String ?? e["type"] as? String ?? "—")
                                                .font(.system(size: 11))
                                            Spacer()
                                            let pts = Int(e["points"] as? Double ?? 0)
                                            Text(pts >= 0 ? "+\(pts)" : "\(pts)")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(pts >= 0 ? Color.green : Color.red)
                                        }
                                    }
                                }
                            }
                        }

                        if !codes.isEmpty || !claims.isEmpty {
                            section("Redemptions") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(codes.enumerated()), id: \.offset) { _, c in
                                        Text("Code · \(c["code"] as? String ?? "—")")
                                            .font(.system(size: 11))
                                    }
                                    ForEach(Array(claims.enumerated()), id: \.offset) { _, c in
                                        Text("Reward · \(c["rewardTitle"] as? String ?? "—") "
                                           + "(\(c["status"] as? String ?? "—"))")
                                            .font(.system(size: 11))
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 620, height: 640)
        .task { await load() }
    }

    private func stat(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 16, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            c()
        }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await AdminAPI.call(
                "GET", "api/admin/bigfan/analytics/users/\(user.id)", session: session)
            if let l = r["listening"] as? [String: Any] {
                hourBuckets = (l["hourBuckets"] as? [Any] ?? []).map { Int($0 as? Double ?? 0) }
                dayBuckets  = (l["dayOfWeekBuckets"] as? [Any] ?? []).map { Int($0 as? Double ?? 0) }
                totalHours  = l["totalHours"] as? Double ?? 0
                sessionCount = Int(l["sessionCount"] as? Double ?? 0)
            }
            if let p = r["points"] as? [String: Any] {
                balance = Int(p["currentBalance"] as? Double ?? 0)
                ledger = p["ledger"] as? [[String: Any]] ?? []
            }
            if let red = r["redemptions"] as? [String: Any] {
                codes = red["codes"] as? [[String: Any]] ?? []
                claims = red["rewardClaims"] as? [[String: Any]] ?? []
            }
            if let loc = r["lastKnownLocation"] as? [String: Any] {
                location = [loc["city"], loc["region"], loc["country"]]
                    .compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Content engagement

struct BigfanEngagementScreen: View {
    let session: AdminSession
    @State private var totalEvents = 0
    @State private var stations: [BigfanAnalyticsModel.Ranked] = []
    @State private var podcasts: [BigfanAnalyticsModel.Ranked] = []
    @State private var interviews: [BigfanAnalyticsModel.Ranked] = []
    @State private var dates: [String] = []
    @State private var series: [(String, [Int])] = []
    @State private var notes: [String] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if let e = error {
                EmptyState(symbol: "exclamationmark.triangle", title: "Could not load", message: e,
                           action: ("Try again", { Task { await load() } }))
            } else if loading {
                ProgressView("Loading engagement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if totalEvents == 0 {
                EmptyState(symbol: "chart.bar.doc.horizontal", title: "No data yet",
                           message: "These figures come from newer event types the app has only "
                                  + "recently started sending, so there is nothing to show.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("\(totalEvents) events recorded")
                            .font(.system(size: 13, weight: .semibold))

                        if !dates.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Daily active listeners, last 30 days")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                Chart {
                                    ForEach(series, id: \.0) { name, values in
                                        ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                                            LineMark(x: .value("Day", i), y: .value("Listeners", v))
                                                .foregroundStyle(by: .value("Kind", name))
                                        }
                                    }
                                }
                                .frame(height: 170)
                            }
                            .padding(14)
                            .background(Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }

                        HStack(alignment: .top, spacing: 14) {
                            ranked("Stations", stations)
                            ranked("Podcasts", podcasts)
                            ranked("Interviews", interviews)
                        }

                        ForEach(notes, id: \.self) { n in
                            Label(n, systemImage: "info.circle")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(22)
                }
            }
        }
        .task { await load() }
    }

    private func ranked(_ t: String, _ rows: [BigfanAnalyticsModel.Ranked]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.system(size: 12, weight: .semibold))
            if rows.isEmpty {
                Text("None").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(rows.prefix(8)) { r in
                    HStack {
                        Text(r.name).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text("\(r.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.16)))
    }

    private func rank(_ a: [[String: Any]]) -> [BigfanAnalyticsModel.Ranked] {
        a.map {
            .init(id: $0["id"] as? String ?? UUID().uuidString,
                  name: $0["name"] as? String ?? $0["title"] as? String ?? "—",
                  count: Int($0["playCount"] as? Double ?? 0))
        }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await AdminAPI.call(
                "GET", "api/admin/bigfan/analytics/content-engagement", session: session)
            totalEvents = Int(r["totalNewEventCount"] as? Double ?? 0)
            if let mp = r["mostPlayed"] as? [String: Any] {
                stations  = rank(mp["stations"]   as? [[String: Any]] ?? [])
                podcasts  = rank(mp["podcasts"]   as? [[String: Any]] ?? [])
                interviews = rank(mp["interviews"] as? [[String: Any]] ?? [])
            }
            if let d = r["dailyActiveListeners"] as? [String: Any] {
                dates = (d["dates"] as? [Any] ?? []).compactMap { $0 as? String }
                series = ["station", "podcast", "interview"].compactMap { k in
                    guard let v = d[k] as? [Any] else { return nil }
                    return (k.capitalized, v.map { Int($0 as? Double ?? 0) })
                }
            }
            notes = (r["notes"] as? [String: Any] ?? [:]).values.compactMap { $0 as? String }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
