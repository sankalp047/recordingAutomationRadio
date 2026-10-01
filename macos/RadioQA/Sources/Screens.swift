import SwiftUI

// MARK: - Today

struct StatusScreen: View {
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
                            model.screen = .find
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
