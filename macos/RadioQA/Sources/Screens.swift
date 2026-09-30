import SwiftUI

// MARK: - Today

struct TodayScreen: View {
    let model: AppModel
    @Binding var selection: Recording?

    private var health: Health {
        guard let c = model.coverage else { return .noData }
        if model.isToday { return .inProgress }
        return c.complete ? .complete : Health.from(
            Double(c.stations.reduce(0) { $0 + $1.hoursOK }) /
            Double(max(c.stations.reduce(0) { $0 + $1.hoursTotal }, 1)))
    }

    private let cols = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusBanner(health: health, title: model.headline, detail: model.subhead)

                Text("Stations").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(model.stations, id: \.self) { st in
                        StationCard(station: st, coverage: model.cov(st), isToday: model.isToday) {
                            model.focusedStation = st
                            model.screen = .stations
                        }
                    }
                }

                if model.isToday {
                    Label("Today is still being recorded, so missing hours are normal until after midnight.",
                          systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
    }
}

// MARK: - Hour by hour

struct TimelineScreen: View {
    let model: AppModel
    @Binding var selection: Recording?

    private let cellW: CGFloat = 46
    private let cellH: CGFloat = 38

    private var hours: [Int] { Array(model.startHour..<model.endHour) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Each square is one hour. Click one to listen.")
                .font(.system(size: 13)).foregroundStyle(.secondary)

            ScrollView([.horizontal]) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Color.clear.frame(width: 120, height: 16)
                        ForEach(hours, id: \.self) { h in
                            Text(HourLabel.compact(h))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(width: cellW)
                        }
                    }
                    ForEach(model.stations, id: \.self) { st in
                        HStack(spacing: 4) {
                            Text(StationName.pretty(st))
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 120, alignment: .leading)
                                .lineLimit(1)
                            ForEach(hours, id: \.self) { h in
                                cell(station: st, hour: h)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            HealthLegend(extra: "a dot marks an hour saved in several pieces")
            Spacer()
        }
        .padding(22)
    }

    private func cell(station: String, hour: Int) -> some View {
        let segs = model.segments(station: station, hour: hour)
        let frac = model.cov(station)?.coverage(forHour: hour)
        let h: Health = segs.isEmpty && model.isToday && hour >= currentHour
            ? .noData : Health.from(frac, hasData: !(segs.isEmpty && frac == nil))
        let isSel = selection.map { segs.contains($0) } == true

        return RoundedRectangle(cornerRadius: 6)
            .fill(h.color.opacity(h == .noData ? 1 : 0.9))
            .frame(width: cellW, height: cellH)
            .overlay(alignment: .bottomTrailing) {
                if segs.count > 1 {
                    Circle().fill(.white.opacity(0.9))
                        .frame(width: 5, height: 5).padding(4)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSel ? Color.primary : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture { if let f = segs.first { selection = f } }
            .help(tip(station: station, hour: hour, health: h, segs: segs))
            .accessibilityLabel("\(StationName.pretty(station)), \(HourLabel.short(hour)): \(h.label)")
    }

    private var currentHour: Int {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return cal.component(.hour, from: Date())
    }

    private func tip(station: String, hour: Int, health: Health, segs: [Recording]) -> String {
        var s = "\(StationName.pretty(station)) — \(HourLabel.short(hour))\n\(health.label)"
        if segs.count > 1 { s += "\nSaved in \(segs.count) pieces (the recorder restarted)" }
        if !segs.isEmpty { s += "\nClick to listen" }
        return s
    }
}

// MARK: - Stations

struct StationsScreen: View {
    let model: AppModel
    @Binding var selection: Recording?

    private var station: String { model.focusedStation ?? model.stations.first ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: Binding(
                get: { station },
                set: { model.focusedStation = $0 })) {
                    ForEach(model.stations, id: \.self) { Text(StationName.pretty($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(22)

            Divider()

            if let c = model.cov(station) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        StatusBanner(
                            health: c.files == 0 ? (model.isToday ? .inProgress : .missing)
                                                 : Health.from(Double(c.hoursOK) / Double(max(c.hoursTotal, 1))),
                            title: c.complete ? "Recorded every hour"
                                              : "\(c.hoursTotal - c.hoursOK) \(c.hoursTotal - c.hoursOK == 1 ? "hour is" : "hours are") incomplete",
                            detail: "\(StationName.pretty(station)) — \(model.friendlyDate). \(c.files) \(c.files == 1 ? "file" : "files") saved.")

                        Text("Hours").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(Array(model.startHour..<model.endHour), id: \.self) { h in
                            hourRow(hour: h, coverage: c)
                        }
                    }
                    .padding(22)
                }
            } else {
                EmptyState(symbol: "questionmark.circle",
                           title: "No information",
                           message: "Nothing has been recorded for this station on \(model.friendlyDate).")
            }
        }
    }

    private func hourRow(hour: Int, coverage c: StationCoverage) -> some View {
        let segs = model.segments(station: station, hour: hour)
        let frac = c.coverage(forHour: hour)
        let h = Health.from(frac, hasData: !segs.isEmpty || frac > 0)
        return HStack(spacing: 12) {
            Text(HourLabel.short(hour))
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 62, alignment: .leading)
            RoundedRectangle(cornerRadius: 4).fill(h.color).frame(width: 8, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.label).font(.system(size: 12, weight: .medium))
                if segs.count > 1 {
                    Text("saved in \(segs.count) pieces — the recorder restarted")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let s = segs.first {
                    Text(s.durationLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let f = segs.first {
                Button {
                    selection = f
                } label: {
                    Label("Listen", systemImage: "play.fill").font(.system(size: 11))
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 7))
    }
}
