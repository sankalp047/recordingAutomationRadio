import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var player = Player()
    @State private var auth = Auth(baseURL: UserDefaults.standard.string(forKey: "baseURL")
                                   ?? "https://radio-api.funasia.net")
    @State private var showSettings = false
    @State private var showLogin = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                dateBar
                Divider()
                body(for: model.screen)
                if player.current != nil {
                    Divider()
                    PlayerBar(player: player)
                }
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, auth: auth) {
                auth.update(baseURL: model.baseURL)
                Task { await model.load(); await model.loadStats() }
            }
        }
        .sheet(isPresented: $showLogin) {
            SignInSheet(baseURL: model.baseURL, auth: auth) {
                showLogin = false
                Task { await model.load(); await model.loadStats() }
            }
        }
        .task {
            await auth.refreshIdentity()
            await model.load()
        }
        .onChange(of: model.needsSignIn) { _, needs in if needs { showLogin = true } }
        .onChange(of: model.selected) { _, new in
            guard let r = new, let url = model.playbackURL(for: r) else { return }
            player.play(r, url: url)
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { model.screen }, set: { model.screen = $0 ?? .today })) {
            Section {
                ForEach(Screen.allCases) { s in
                    NavigationLink(value: s) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.system(size: 13))
                                Text(s.blurb).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: s.icon) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 214, ideal: 224, max: 260)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                if auth.signedIn, let id = auth.identity {
                    HStack(spacing: 7) {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Signed in").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(id.display).font(.system(size: 11)).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            Task { await auth.signOut() }
                        } label: { Image(systemName: "rectangle.portrait.and.arrow.right") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Sign out")
                    }
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        Label("Sign in", systemImage: "person.crop.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    // MARK: date bar

    private var dateBar: some View {
        HStack(spacing: 10) {
            Button { model.shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous day")
            VStack(alignment: .leading, spacing: 0) {
                Text(model.friendlyDate).font(.system(size: 14, weight: .semibold))
                Text(model.dateString).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(minWidth: 108, alignment: .leading)
            Button { model.shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .help("Next day")
                .disabled(model.isToday)
            DatePicker("", selection: $model.date, displayedComponents: .date)
                .datePickerStyle(.field).labelsHidden().frame(width: 116)
                .onChange(of: model.date) { _, _ in Task { await model.load() } }
            if !model.isToday {
                Button("Today") { model.date = Date(); Task { await model.load() } }
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            if !model.recordings.isEmpty {
                Text("\(model.recordings.count) files · \(model.totalSize)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { Task { await model.load(); await model.loadStats() } } label: {
                Image(systemName: "arrow.clockwise")
            }.help("Refresh")
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    // MARK: content

    @ViewBuilder
    private func body(for screen: Screen) -> some View {
        if !model.isConfigured {
            EmptyState(symbol: "gearshape",
                       title: "Almost ready",
                       message: "Add the server address and access key so the app can reach your recordings.",
                       action: ("Open Settings", { showSettings = true }))
        } else if model.needsSignIn {
            EmptyState(symbol: "person.crop.circle.badge.questionmark",
                       title: "Please sign in",
                       message: "Use your funasia.net account to see the recordings.",
                       action: ("Sign in", { showLogin = true }))
        } else if let e = model.error {
            EmptyState(symbol: "exclamationmark.triangle", title: "Could not load", message: e,
                       action: ("Try again", { Task { await model.load() } }))
        } else if model.loading && model.coverage == nil {
            ProgressView("Loading \(model.friendlyDate.lowercased())…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch screen {
            case .today:    TodayScreen(model: model, selection: $model.selected)
            case .timeline: TimelineScreen(model: model, selection: $model.selected)
            case .stations: StationsScreen(model: model, selection: $model.selected)
            case .health:   HealthScreen(model: model)
            }
        }
    }
}

// MARK: - Sign in

struct SignInSheet: View {
    let baseURL: String
    let auth: Auth
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in").font(.system(size: 15, weight: .semibold))
                    Text("Use your funasia.net account. Other accounts are not allowed.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(16)
            Divider()
            if let url = URL(string: baseURL + "/health") {
                AccessLoginWebView(url: url) { store in
                    Task {
                        await auth.adoptCookies(from: store)
                        dismiss()
                        onDone()
                    }
                }
            } else {
                EmptyState(symbol: "link.badge.plus", title: "Bad server address",
                           message: "Check the address in Settings.")
            }
        }
        .frame(width: 560, height: 620)
    }
}

// MARK: - Player

struct PlayerBar: View {
    let player: Player

    var body: some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)

            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .buttonStyle(.plain).help("Back 15 seconds")
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                .buttonStyle(.plain).help("Forward 15 seconds")

            if let c = player.current {
                VStack(alignment: .leading, spacing: 0) {
                    Text(StationName.pretty(c.station)).font(.system(size: 12, weight: .medium))
                    Text("\(HourLabel.short(c.startHour)) · \(c.durationLabel)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(width: 138, alignment: .leading)
            }

            Text(Player.time(player.position))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 1))
            Text(Player.time(player.duration))
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()

            Button { player.stop() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close player")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.bar)
    }
}
