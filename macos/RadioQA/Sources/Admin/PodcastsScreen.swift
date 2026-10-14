import SwiftUI

/// Shows. One of only three screens a plain admin can see, so it is gated at
/// admin rather than superadmin — only the Activity Log inside it is
/// superadmin-only, exactly as on the web.
@MainActor
@Observable
final class PodcastsModel {
    struct Show: Identifiable, Equatable {
        var id: String
        var showTitle = ""
        var hostName = ""
        var stationId = ""            // "<stationDocId>::<stationName>"
        var coverUrl = ""
        var feedUrl = ""
        var featuredVideoUrl = ""
        var description = ""
        var showDaysOverride = ""
        var showTimeOverride = ""
        var featured = false
        var active = true

        /// Podcasts are matched to stations by NAME, not id, so renaming a
        /// station orphans its shows. Keep the name half intact.
        var stationName: String { stationId.components(separatedBy: "::").last ?? "" }
    }

    struct Station: Identifiable, Hashable {
        let id: String
        let name: String
        var composite: String { "\(id)::\(name)" }
    }

    struct AuditEntry: Identifiable {
        let id: String
        let summary: String
        let changedBy: String
        let changedAt: String
    }

    private let session: AdminSession
    private(set) var shows: [Show] = []
    private(set) var stations: [Station] = []
    private(set) var audit: [AuditEntry] = []
    private(set) var loading = false
    var error: String?

    init(session: AdminSession) { self.session = session }

    private func ready() async -> (String, FirebaseREST.Config)? {
        guard let c = session.firebaseConfig, let t = await session.validToken() else {
            error = "Not signed in."; return nil
        }
        return (t, c)
    }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        guard let (token, config) = await ready() else { return }
        do {
            async let showsDocs = FirebaseREST.list(collection: "podcasts", token: token, config: config)
            async let stationDocs = FirebaseREST.list(collection: "stations", token: token, config: config)
            let (sd, std) = try await (showsDocs, stationDocs)

            shows = sd.map { d in
                var s = Show(id: d.id)
                s.showTitle = d.fields["showTitle"] as? String ?? ""
                s.hostName = d.fields["hostName"] as? String ?? ""
                s.stationId = d.fields["stationId"] as? String ?? ""
                s.coverUrl = d.fields["coverUrl"] as? String ?? ""
                s.feedUrl = d.fields["feedUrl"] as? String ?? ""
                s.featuredVideoUrl = d.fields["featuredVideoUrl"] as? String ?? ""
                s.description = d.fields["description"] as? String ?? ""
                s.showDaysOverride = d.fields["showDaysOverride"] as? String ?? ""
                s.showTimeOverride = d.fields["showTimeOverride"] as? String ?? ""
                s.featured = d.fields["featured"] as? Bool ?? false
                s.active = d.fields["active"] as? Bool ?? true
                return s
            }
            .sorted { $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending }

            // the picker offers active stations only, as the web admin does
            stations = std
                .filter { ($0.fields["active"] as? Bool) ?? true }
                .map { Station(id: $0.id, name: $0.fields["name"] as? String ?? "") }
                .sorted { $0.name < $1.name }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func save(_ show: Show) async -> Bool {
        error = nil
        guard !show.showTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "Show title is required."; return false
        }
        guard let (token, config) = await ready() else { return false }
        let payload: [String: Any] = [
            "showTitle": show.showTitle, "hostName": show.hostName,
            "stationId": show.stationId, "coverUrl": show.coverUrl,
            "feedUrl": show.feedUrl, "featuredVideoUrl": show.featuredVideoUrl,
            "description": show.description,
            "showDaysOverride": show.showDaysOverride,
            "showTimeOverride": show.showTimeOverride,
            "featured": show.featured, "active": show.active,
        ]
        do {
            let creating = show.id.isEmpty
            if creating {
                try await FirebaseREST.create(collection: "podcasts", fields: payload,
                                              token: token, config: config)
            } else {
                try await FirebaseREST.update(path: "podcasts/\(show.id)", fields: payload,
                                              token: token, config: config)
            }
            await writeAudit(action: creating ? "create" : "update",
                             docId: show.id, title: show.showTitle)
            await load()
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func delete(_ show: Show) async {
        guard let (token, config) = await ready() else { return }
        do {
            try await FirebaseREST.delete(path: "podcasts/\(show.id)", token: token, config: config)
            await writeAudit(action: "delete", docId: show.id, title: show.showTitle)
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Best-effort, exactly like the web: a failed audit write never blocks
    /// the edit that succeeded.
    private func writeAudit(action: String, docId: String, title: String) async {
        guard let (token, config) = await ready() else { return }
        guard case let .signedIn(email, _) = session.state else { return }
        let verb = ["create": "Created", "update": "Updated", "delete": "Deleted"][action] ?? action
        let fields: [String: Any] = [
            "collection": "podcasts",
            "action": action,
            "docId": docId,
            "docTitle": title.isEmpty ? docId : title,
            "changedBy": email,
            "changedByUid": session.uid ?? "",
            "changedAt": ISO8601DateFormatter().string(from: Date()),
            "summary": "\(verb) “\(title.isEmpty ? docId : title)”",
        ]
        try? await FirebaseREST.create(collection: "podcastAuditLogs", fields: fields,
                                       token: token, config: config)
    }

    /// Superadmin only, enforced by the Firestore rules as well as the UI.
    func loadAudit() async {
        guard let (token, config) = await ready() else { return }
        do {
            let docs = try await FirebaseREST.list(collection: "podcastAuditLogs",
                                                   token: token, config: config)
            audit = docs.map {
                AuditEntry(id: $0.id,
                           summary: $0.fields["summary"] as? String ?? "",
                           changedBy: $0.fields["changedBy"] as? String ?? "unknown",
                           changedAt: $0.fields["changedAt"] as? String ?? "")
            }
            .sorted { $0.changedAt > $1.changedAt }
            .prefix(100).map { $0 }
        } catch {
            self.error = "Activity log: " +
                ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

struct PodcastsScreen: View {
    let session: AdminSession
    @State private var model: PodcastsModel
    @State private var editing: PodcastsModel.Show?
    @State private var confirmDelete: PodcastsModel.Show?
    @State private var showAudit = false
    @State private var search = ""

    init(session: AdminSession) {
        self.session = session
        _model = State(initialValue: PodcastsModel(session: session))
    }

    private var shown: [PodcastsModel.Show] {
        guard !search.isEmpty else { return model.shows }
        return model.shows.filter {
            $0.showTitle.localizedCaseInsensitiveContains(search)
            || $0.hostName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search shows or hosts", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(model.shows.count) show\(model.shows.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if session.role?.isSuper == true {
                    Button {
                        showAudit = true
                        Task { await model.loadAudit() }
                    } label: { Label("Activity log", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12)) }
                }
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                Button { editing = .init(id: "") } label: { Label("New show", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()

            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange).padding(12)
            }

            if model.shows.isEmpty && !model.loading {
                EmptyState(symbol: "headphones", title: "No shows yet",
                           message: "Shows added here feed the website and the podcast listings.")
            } else {
                List(shown) { show in
                    HStack(spacing: 11) {
                        if let u = URL(string: show.coverUrl), !show.coverUrl.isEmpty {
                            AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fill) }
                                placeholder: { Color.secondary.opacity(0.12) }
                                .frame(width: 44, height: 44).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12))
                                .frame(width: 44, height: 44)
                                .overlay(Image(systemName: "headphones").foregroundStyle(.secondary))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(show.showTitle.isEmpty ? "(untitled)" : show.showTitle)
                                .font(.system(size: 13, weight: .medium))
                            Text([show.hostName, show.stationName]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if show.featured {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                                .font(.system(size: 11)).help("Featured")
                        }
                        if !show.active {
                            Text("inactive").font(.system(size: 10))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 3))
                        }
                        Button("Edit") { editing = show }.controlSize(.small)
                        Button(role: .destructive) { confirmDelete = show } label: {
                            Image(systemName: "trash")
                        }.controlSize(.small)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .task { await model.load() }
        .sheet(item: $editing) { show in PodcastEditor(model: model, show: show) }
        .sheet(isPresented: $showAudit) { auditSheet }
        .alert("Delete this show?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let s = confirmDelete { Task { await model.delete(s) } }
                confirmDelete = nil
            }
        } message: { Text("“\(confirmDelete?.showTitle ?? "")” will be removed.") }
    }

    private var auditSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity log").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { showAudit = false }
            }
            .padding(16)
            Divider()
            if model.audit.isEmpty {
                EmptyState(symbol: "clock", title: "Nothing logged yet",
                           message: "Changes to shows are recorded here.")
            } else {
                List(model.audit) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.summary).font(.system(size: 12))
                        Text("\(e.changedBy) · \(e.changedAt.prefix(16).replacingOccurrences(of: "T", with: " "))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 560)
    }
}

struct PodcastEditor: View {
    let model: PodcastsModel
    @State var show: PodcastsModel.Show
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(show.id.isEmpty ? "New show" : "Edit show")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    row("Show title", required: true) {
                        TextField("", text: $show.showTitle).textFieldStyle(.roundedBorder)
                    }
                    row("Host", required: false) {
                        TextField("", text: $show.hostName).textFieldStyle(.roundedBorder)
                    }
                    row("Station", required: false) {
                        VStack(alignment: .leading, spacing: 3) {
                            Picker("", selection: $show.stationId) {
                                Text("—").tag("")
                                ForEach(model.stations) { s in Text(s.name).tag(s.composite) }
                                // keep an orphaned value visible instead of silently clearing it
                                if !show.stationId.isEmpty,
                                   !model.stations.contains(where: { $0.composite == show.stationId }) {
                                    Text("\(show.stationName) (station missing)").tag(show.stationId)
                                }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 260)
                            Text("Shows are matched to stations by name, so renaming a station hides its shows.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    row("Feed URL", required: false) {
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("https://funasia-rss.streamguys1.com/funasia/….json", text: $show.feedUrl)
                                .textFieldStyle(.roundedBorder)
                            Text("StreamGuys JSON feed. Episodes are read from here, never stored.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    row("Cover image URL", required: false) {
                        TextField("", text: $show.coverUrl).textFieldStyle(.roundedBorder)
                    }
                    row("Featured video URL", required: false) {
                        TextField("", text: $show.featuredVideoUrl).textFieldStyle(.roundedBorder)
                    }
                    row("Description", required: false) {
                        TextEditor(text: $show.description).font(.system(size: 12)).frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.secondary.opacity(0.3)))
                    }
                    HStack(spacing: 14) {
                        row("Days override", required: false) {
                            TextField("e.g. Mon–Fri", text: $show.showDaysOverride)
                                .textFieldStyle(.roundedBorder).frame(width: 150)
                        }
                        row("Time override", required: false) {
                            TextField("e.g. 2–4 PM", text: $show.showTimeOverride)
                                .textFieldStyle(.roundedBorder).frame(width: 150)
                        }
                    }
                    Text("Leave the overrides empty to use the schedule from the feed.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack(spacing: 20) {
                        Toggle(isOn: $show.featured) { Text("Featured").font(.system(size: 12)) }
                        Toggle(isOn: $show.active) { Text("Active").font(.system(size: 12)) }
                    }
                    .toggleStyle(.switch)
                }
                .padding(18)
            }

            Divider()
            HStack {
                if let e = model.error {
                    Text(e).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save") {
                    Task { saving = true; if await model.save(show) { dismiss() }; saving = false }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving)
            }
            .padding(16)
        }
        .frame(width: 580, height: 660)
    }

    @ViewBuilder
    private func row<C: View>(_ label: String, required: Bool, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium))
                if required { Text("required").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            c()
        }
    }
}
