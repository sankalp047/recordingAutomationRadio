import SwiftUI

/// How the recorder has been performing over time: reliability per station,
/// how often it restarted, and which days had gaps.
struct HealthScreen: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("How it has been doing")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.historyDays },
                        set: { model.historyDays = $0; Task { await model.loadStats() } })) {
                            Text("7 days").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 290)
                }

                if let s = model.stats {
                    ForEach(s.stations) { st in stationBlock(st) }
                    footnote
                } else {
                    EmptyState(symbol: "chart.bar",
                               title: "Nothing to show yet",
                               message: "History appears once at least one full day has been recorded.")
                }
            }
            .padding(22)
        }
        .task { await model.loadStats() }
    }

    private func stationBlock(_ st: StationStats) -> some View {
        let sm = st.summary
        let health = Health.from(sm.reliability, hasData: sm.totalFiles > 0)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(StationName.pretty(st.station)).font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: health.symbol).foregroundStyle(health.color)
                Text("\(Int(sm.reliability * 100))% of hours recorded")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(health.color)
            }

            // one bar per day, tallest = complete
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(st.days) { d in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Health.from(d.fraction, hasData: d.hasData).color)
                            .frame(height: max(4, 46 * (d.hasData ? d.fraction : 0.06)))
                        Text(String(d.date.suffix(2)))
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: 26)
                    .help("\(d.date): \(d.hasData ? "\(d.hoursOK)/\(d.hoursTotal) hours" : "nothing recorded")"
                          + (d.restarts > 0 ? "\n\(d.restarts) restart\(d.restarts == 1 ? "" : "s")" : ""))
                }
            }
            .frame(height: 62, alignment: .bottom)

            HStack(spacing: 22) {
                metric("Complete days", "\(sm.daysComplete) of \(sm.daysCounted)")
                metric("Hours recorded", "\(sm.totalHoursOK) of \(sm.totalHoursExpected)")
                metric("Restarts", "\(sm.totalRestarts)",
                       warn: sm.totalRestarts > sm.daysCounted * 2)
                metric("Stored", ByteCountFormatter.string(
                    fromByteCount: Int64(sm.totalBytes), countStyle: .file))
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.16)))
    }

    private func metric(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(warn ? Color.orange : Color.primary)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("A restart means the recorder reconnected mid-hour and that hour was saved in several pieces. The audio is still complete — a few restarts a day is normal.",
                  systemImage: "info.circle")
            Label("Days before the recorder was set up show as empty, not as failures.",
                  systemImage: "calendar")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}
