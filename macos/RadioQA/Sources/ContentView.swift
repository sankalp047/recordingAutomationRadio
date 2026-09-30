import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var player = Player()
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if !model.isConfigured {
                placeholder("Not configured",
                            "Add the server URL and API token in Settings.",
                            systemImage: "gearshape")
            } else if let e = model.error {
                placeholder("Could not load", e, systemImage: "exclamationmark.triangle")
            } else if model.loading && model.coverage == nil {
                ProgressView("Loading \(model.dateString)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }

            if player.current != nil {
                Divider()
                PlayerBar(player: player)
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model) { Task { await model.load() } }
        }
        .task {
            await model.loadStations()
            await model.load()
        }
        .onChange(of: model.selected) { _, new in
            guard let r = new, let url = model.playbackURL(for: r) else { return }
            player.play(r, url: url)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { model.shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous day")

            DatePicker("", selection: $model.date, displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .frame(width: 120)
                .onChange(of: model.date) { _, _ in Task { await model.load() } }

            Button { model.shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .help("Next day")

            Button("Today") {
                model.date = Date()
                Task { await model.load() }
            }

            if let c = model.coverage {
                Label(c.complete ? "All stations complete" : "Gaps found",
                      systemImage: c.complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(c.complete ? .green : .orange)
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()

            if model.loading { ProgressView().controlSize(.small) }
            Text("\(model.recordings.count) files · \(model.totalSize)")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var content: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Coverage — \(model.dateString)")
                    .font(.system(size: 13, weight: .medium))
                CoverageGrid(model: model, selection: $model.selected)
                Spacer()
            }
            .padding(14)
            .frame(minWidth: 620)

            RecordingList(model: model, selection: $model.selected)
                .frame(minWidth: 280)
        }
    }

    private func placeholder(_ title: String, _ msg: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(msg).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Open Settings") { showSettings = true }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingList: View {
    let model: AppModel
    @Binding var selection: Recording?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recordings").font(.system(size: 13, weight: .medium)).padding(14)
            Divider()
            if model.recordings.isEmpty {
                Text("Nothing recorded on this day.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.recordings, selection: $selection) { r in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.station)  \(r.startLocal)")
                                .font(.system(size: 12, design: .monospaced))
                            HStack(spacing: 6) {
                                Text(r.durationLabel)
                                if r.isPartial {
                                    Text("partial")
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.22),
                                                    in: RoundedRectangle(cornerRadius: 3))
                                }
                                Text(r.sizeLabel)
                            }
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.circle")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = r }
                    .tag(r)
                }
                .listStyle(.inset)
            }
        }
    }
}

struct PlayerBar: View {
    let player: Player

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }

            if let c = player.current {
                Text("\(c.station) \(c.startLocal)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(Player.time(player.position))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()

            Slider(value: Binding(get: { player.position },
                                  set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 1))

            Text(Player.time(player.duration))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()

            Button { player.stop() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}
