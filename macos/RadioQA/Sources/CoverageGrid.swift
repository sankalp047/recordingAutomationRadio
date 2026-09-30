import SwiftUI

/// Stations down, broadcast hours across. This is the whole point of the app:
/// one glance tells you whether yesterday recorded.
struct CoverageGrid: View {
    let model: AppModel
    @Binding var selection: Recording?

    private let cell = CGSize(width: 34, height: 30)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    hourHeader
                    ForEach(model.stations, id: \.self) { station in
                        row(for: station)
                    }
                }
                .padding(.vertical, 4)
            }
            legend
        }
    }

    private var hours: [Int] { Array(model.startHour..<model.endHour) }

    private var hourHeader: some View {
        HStack(spacing: 3) {
            Text("").frame(width: 92, alignment: .leading)
            ForEach(hours, id: \.self) { h in
                Text(String(format: "%02d", h))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: cell.width)
            }
        }
    }

    private func row(for station: String) -> some View {
        let cov = model.coverage?.stations.first { $0.station == station }
        return HStack(spacing: 3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(station).font(.system(size: 12, weight: .medium))
                if let c = cov {
                    Text("\(c.hoursOK)/\(c.hoursTotal)")
                        .font(.system(size: 10))
                        .foregroundStyle(c.complete ? Color.secondary : Color.red)
                }
            }
            .frame(width: 92, alignment: .leading)

            ForEach(hours, id: \.self) { h in
                cellView(station: station, hour: h, value: cov?.coverage(forHour: h))
            }
        }
    }

    private func cellView(station: String, hour: Int, value: Double?) -> some View {
        let segs = model.segments(station: station, hour: hour)
        let v = value ?? 0
        return RoundedRectangle(cornerRadius: 4)
            .fill(color(for: value))
            .frame(width: cell.width, height: cell.height)
            .overlay {
                // more than one segment in an hour = the recorder restarted
                if segs.count > 1 {
                    Text("\(segs.count)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selection.map { segs.contains($0) } == true
                                  ? Color.accentColor : .clear, lineWidth: 2)
            }
            .help(tooltip(station: station, hour: hour, value: v, segs: segs))
            .onTapGesture { if let first = segs.first { selection = first } }
            .accessibilityLabel("\(station) \(hour):00, \(Int(v * 100)) percent")
    }

    private func color(for value: Double?) -> Color {
        guard let v = value else { return Color.gray.opacity(0.18) }
        if v >= 0.95 { return .green.opacity(0.75) }
        if v >= 0.5  { return .yellow.opacity(0.85) }
        if v > 0     { return .orange.opacity(0.85) }
        return .red.opacity(0.7)
    }

    private func tooltip(station: String, hour: Int, value: Double, segs: [Recording]) -> String {
        var s = "\(station)  \(String(format: "%02d:00", hour))  \(Int(value * 100))% covered"
        if segs.count > 1 { s += "\n\(segs.count) segments (recorder restarted)" }
        else if segs.isEmpty { s += "\nno audio" }
        return s
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([("complete", Color.green.opacity(0.75)),
                     ("partial", Color.yellow.opacity(0.85)),
                     ("mostly missing", Color.orange.opacity(0.85)),
                     ("no audio", Color.red.opacity(0.7))], id: \.0) { label, c in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 11, height: 11)
                    Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("a number means that hour arrived in several parts")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}
