import SwiftUI

/// One vocabulary for "how did this hour go", used everywhere so the colours
/// and the words always agree.
enum Health {
    case complete, partial, mostlyMissing, missing, noData, inProgress

    static func from(_ fraction: Double?, hasData: Bool = true) -> Health {
        guard let f = fraction else { return .noData }
        if !hasData { return .noData }
        if f >= 0.95 { return .complete }
        if f >= 0.5  { return .partial }
        if f > 0     { return .mostlyMissing }
        return .missing
    }

    var color: Color {
        switch self {
        case .complete:      return Color(red: 0.20, green: 0.70, blue: 0.42)
        case .partial:       return Color(red: 0.95, green: 0.72, blue: 0.20)
        case .mostlyMissing: return Color(red: 0.94, green: 0.54, blue: 0.18)
        case .missing:       return Color(red: 0.86, green: 0.28, blue: 0.28)
        case .noData:        return Color.secondary.opacity(0.22)
        case .inProgress:    return Color.accentColor.opacity(0.45)
        }
    }

    var label: String {
        switch self {
        case .complete:      return "Recorded"
        case .partial:       return "Partly recorded"
        case .mostlyMissing: return "Mostly missing"
        case .missing:       return "Not recorded"
        case .noData:        return "Nothing yet"
        case .inProgress:    return "In progress"
        }
    }

    var symbol: String {
        switch self {
        case .complete:      return "checkmark.circle.fill"
        case .partial:       return "exclamationmark.circle.fill"
        case .mostlyMissing: return "exclamationmark.triangle.fill"
        case .missing:       return "xmark.circle.fill"
        case .noData:        return "circle.dashed"
        case .inProgress:    return "clock.fill"
        }
    }
}

/// Big readable status banner.
struct StatusBanner: View {
    let health: Health
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: health.symbol)
                .font(.system(size: 34))
                .foregroundStyle(health.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 21, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(health.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(health.color.opacity(0.28)))
    }
}

/// Per-station summary card.
struct StationCard: View {
    let station: String
    let coverage: StationCoverage?
    let isToday: Bool
    var onOpen: () -> Void

    private var health: Health {
        guard let c = coverage else { return .noData }
        if c.files == 0 { return isToday ? .inProgress : .missing }
        return Health.from(Double(c.hoursOK) / Double(max(c.hoursTotal, 1)))
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(StationName.pretty(station))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: health.symbol).foregroundStyle(health.color)
                }
                if let c = coverage {
                    Text("\(c.hoursOK) of \(c.hoursTotal) hours")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    ProgressView(value: Double(c.hoursOK), total: Double(max(c.hoursTotal, 1)))
                        .tint(health.color)
                    if c.gaps.isEmpty {
                        Text(isToday ? "No problems so far" : "Complete")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text(gapSentence(c))
                            .font(.system(size: 11))
                            .foregroundStyle(health.color)
                            .lineLimit(2)
                    }
                } else {
                    Text("No information").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    private func gapSentence(_ c: StationCoverage) -> String {
        let hours = c.gaps.map { HourLabel.short($0.hour) }
        if hours.count <= 3 { return "Missing: " + hours.joined(separator: ", ") }
        return "Missing: \(hours.prefix(3).joined(separator: ", ")) +\(hours.count - 3) more"
    }
}

/// Legend that names the colours, so nobody has to guess.
struct HealthLegend: View {
    var extra: String?
    var body: some View {
        HStack(spacing: 16) {
            ForEach([Health.complete, .partial, .mostlyMissing, .missing], id: \.label) { h in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(h.color).frame(width: 11, height: 11)
                    Text(h.label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let e = extra {
                Text(e).font(.system(size: 11)).foregroundStyle(.secondary).italic()
            }
            Spacer()
        }
    }
}

struct EmptyState: View {
    let symbol: String, title: String, message: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if let a = action { Button(a.label, action: a.run).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
