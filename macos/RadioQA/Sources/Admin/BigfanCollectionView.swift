import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One screen driving every BigFan catalogue collection from its config,
/// mirroring the web admin's BigfanCRUD. Reads and writes go through the
/// admin backend, because BigFan is a separate Firebase project reached with
/// its own service account.
@MainActor
@Observable
final class BigfanModel {
    let spec: BigfanSpec
    private let session: AdminSession

    private(set) var items: [[String: Any]] = []
    private(set) var stations: [(id: String, name: String)] = []
    private(set) var interviews: [(id: String, name: String)] = []
    private(set) var loading = false
    var error: String?
    var uploading: String?

    init(spec: BigfanSpec, session: AdminSession) {
        self.spec = spec
        self.session = session
    }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            items = try await AdminAPI.bigfanList(spec.key, session: session)
            await loadPickerSources()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// stationSelect and contentSelect fields are filled from other BigFan
    /// collections, so fetch them only when a field actually needs them.
    private func loadPickerSources() async {
        let types = Set(spec.fields.map(\.type))
        if types.contains("stationSelect") || types.contains("contentSelect") {
            if let rows = try? await AdminAPI.bigfanList("stations", session: session) {
                stations = rows.compactMap {
                    guard let id = $0["id"] as? String else { return nil }
                    return (id, $0["name"] as? String ?? id)
                }.sorted { $0.name < $1.name }
            }
        }
        if types.contains("contentSelect") {
            if let rows = try? await AdminAPI.bigfanList("interviews", session: session) {
                interviews = rows.compactMap {
                    guard let id = $0["id"] as? String else { return nil }
                    return (id, $0["title"] as? String ?? id)
                }.sorted { $0.name < $1.name }
            }
        }
    }

    func save(id: String?, values: [String: Any]) async -> Bool {
        error = nil
        // The server checks required fields on create and reports labels;
        // check here too so the user isn't round-tripped for a blank box.
        let missing = spec.fields.filter { f in
            guard f.isRequired, visible(f, in: values) else { return false }
            return isEmpty(values[f.name])
        }
        if id == nil, !missing.isEmpty {
            error = "Missing required field(s): " + missing.map(\.label).joined(separator: ", ")
            return false
        }
        do {
            if let id {
                try await AdminAPI.bigfanUpdate(spec.key, id: id, payload(values), session: session)
            } else {
                _ = try await AdminAPI.bigfanCreate(spec.key, payload(values), session: session)
            }
            await load()
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Only configured fields are sent. Docs also carry fields written by the
    /// mobile app; the server drops unknown keys, but not echoing them keeps
    /// the payload honest and under the 32 KB cap.
    private func payload(_ values: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for f in spec.fields {
            if !visible(f, in: values) {
                // hidden by showIf: still sent, cleared
                out[f.name] = (f.type == "stringArray" || f.type == "multiSelect") ? [String]() : ""
                continue
            }
            out[f.name] = values[f.name] ?? ""
        }
        return out
    }

    func patchStatus(id: String, status: String) async {
        do {
            try await AdminAPI.bigfanUpdate(spec.key, id: id, ["status": status], session: session)
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Only offered for randomDraw questions that have closed and have no
    /// winner. The server draws from correct answers, writes the winner
    /// fields and emails them.
    func pickWinner(id: String) async -> String? {
        error = nil
        do {
            let r = try await AdminAPI.pickWinner(questionId: id, session: session)
            await load()
            let email = r["winnerUserEmail"] as? String ?? "someone"
            let code = r["winnerCode"] as? String ?? ""
            return "Winner drawn: \(email)\(code.isEmpty ? "" : " · code \(code)")"
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func canPickWinner(_ item: [String: Any]) -> Bool {
        guard spec.key == "trivia-questions" else { return false }
        guard (item["winnerMethod"] as? String) == "randomDraw" else { return false }
        guard (item["winnerUserId"] as? String ?? "").isEmpty else { return false }
        guard let closes = item["closesAt"] as? String,
              let d = CentralTime.parse(closes) else { return false }
        return d < Date()          // only after it closes
    }

    func delete(id: String) async {
        do {
            try await AdminAPI.bigfanDelete(spec.key, id: id, session: session)
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Images go to the MAIN project's Storage, not BigFan's.
    func upload(_ url: URL) async -> String? {
        guard let config = session.firebaseConfig, let token = await session.validToken(),
              let data = try? Data(contentsOf: url) else { return nil }
        uploading = "Uploading…"
        defer { uploading = nil }
        let path = "bigfan/\(spec.key)/\(Int(Date().timeIntervalSince1970 * 1000))_\(url.lastPathComponent)"
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        do {
            return try await FirebaseREST.upload(data: data, to: path, contentType: type,
                                                 token: token, config: config)
        } catch {
            self.error = "Upload failed: "
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                + " — if the storage rules now require the admin claim, sign out and back in."
            return nil
        }
    }

    func visible(_ f: BigfanField, in values: [String: Any]) -> Bool {
        guard let s = f.showIf else { return true }
        return (values[s.field] as? String) == s.value
    }

    private func isEmpty(_ v: Any?) -> Bool {
        switch v {
        case nil: return true
        case let s as String: return s.trimmingCharacters(in: .whitespaces).isEmpty
        case let a as [Any]: return a.isEmpty
        default: return false
        }
    }

    func text(_ item: [String: Any], _ f: BigfanField) -> String {
        let v = item[f.name]
        switch f.type {
        case "checkbox": return (v as? Bool ?? false) ? "Yes" : "No"
        case "datetime": return (v as? String).map { CentralTime.display($0) } ?? ""
        case "date":     return (v as? String).map { CentralTime.displayDate($0) } ?? ""
        case "stringArray", "multiSelect":
            return ((v as? [Any])?.compactMap { $0 as? String } ?? []).joined(separator: ", ")
        case "number":
            guard let d = v as? Double else { return v.map { "\($0)" } ?? "" }
            return d == d.rounded() ? String(Int(d)) : String(d)
        default: return v as? String ?? (v.map { "\($0)" } ?? "")
        }
    }
}

struct BigfanCollectionView: View {
    let spec: BigfanSpec
    let session: AdminSession
    @State private var model: BigfanModel
    @State private var search = ""
    @State private var editing: EditTarget?
    @State private var confirmDelete: String?
    @State private var confirmWinner: String?
    @State private var winnerResult: String?

    struct EditTarget: Identifiable {
        let id: String        // "" for a new record
        var values: [String: Any]
    }

    init(spec: BigfanSpec, session: AdminSession) {
        self.spec = spec
        self.session = session
        _model = State(initialValue: BigfanModel(spec: spec, session: session))
    }

    private var shown: [[String: Any]] {
        guard !search.isEmpty, let sf = spec.searchField else { return model.items }
        return model.items.filter {
            ($0[sf] as? String ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let sf = spec.searchField {
                    TextField("Search \(sf)", text: $search)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(model.items.count) record\(model.items.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                if !spec.isReadOnly {
                    Button {
                        editing = .init(id: "", values: BigfanCatalog.blank(spec))
                    } label: { Label("New", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            Divider()

            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }

            if spec.isReadOnly && spec.patchOnly.isEmpty {
                Label("This list is written by the mobile app and cannot be edited here.",
                      systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }

            if model.items.isEmpty && !model.loading && model.error == nil {
                EmptyState(symbol: "tray", title: "Nothing here yet",
                           message: "No \(spec.title.lowercased()) exist in the BigFan app.")
            } else {
                List(Array(shown.enumerated()), id: \.offset) { _, item in
                    row(item)
                }
                .listStyle(.inset)
            }
        }
        .task { await model.load() }
        .sheet(item: $editing) { target in
            BigfanEditor(model: model, spec: spec, target: target)
        }
        .alert("Delete this record?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = confirmDelete { Task { await model.delete(id: id) } }
                confirmDelete = nil
            }
        } message: { Text("This affects the live BigFan app. Deletes do not cascade.") }
        .alert("Draw a winner?", isPresented: Binding(
            get: { confirmWinner != nil }, set: { if !$0 { confirmWinner = nil } })) {
            Button("Cancel", role: .cancel) { confirmWinner = nil }
            Button("Draw winner") {
                if let id = confirmWinner {
                    Task { winnerResult = await model.pickWinner(id: id) }
                }
                confirmWinner = nil
            }
        } message: {
            Text("One correct answer is picked at random. The winner is recorded and emailed. "
               + "This cannot be undone.")
        }
        .alert("Winner drawn", isPresented: Binding(
            get: { winnerResult != nil }, set: { if !$0 { winnerResult = nil } })) {
            Button("OK") { winnerResult = nil }
        } message: { Text(winnerResult ?? "") }
    }

    @ViewBuilder
    private func row(_ item: [String: Any]) -> some View {
        let id = item["id"] as? String ?? ""
        HStack(spacing: 11) {
            if let f = spec.fields.first(where: { $0.type == "image" }),
               let s = item[f.name] as? String, !s.isEmpty, let u = URL(string: s) {
                AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fill) }
                    placeholder: { Color.secondary.opacity(0.12) }
                    .frame(width: 44, height: 34).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(spec.columns.filter { $0.type != "image" }.prefix(2))) { f in
                    Text(model.text(item, f))
                        .font(.system(size: f.name == spec.columns.first?.name ? 13 : 11,
                                      weight: f.name == spec.columns.first?.name ? .medium : .regular))
                        .foregroundStyle(f.name == spec.columns.first?.name ? .primary : .secondary)
                        .lineLimit(1)
                }
                // read-only lists have no configured fields, so show the data
                if spec.columns.isEmpty {
                    Text(summaryFor(item)).font(.system(size: 12)).lineLimit(2)
                }
            }
            Spacer()
            if model.canPickWinner(item) {
                Button("Pick winner") { confirmWinner = id }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .help("Draw at random from the correct answers")
            }
            if spec.key == "reward-claims", let status = item["status"] as? String {
                Text(status).font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(status == "won" ? Color.green.opacity(0.2) : Color.secondary.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 4))
                if status != "won" {
                    Button("Mark won") { Task { await model.patchStatus(id: id, status: "won") } }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
            if !spec.isReadOnly {
                Button("Edit") { editing = .init(id: id, values: item) }.controlSize(.small)
                Button(role: .destructive) { confirmDelete = id } label: { Image(systemName: "trash") }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    /// For collections with no field config, show whatever the data has.
    private func summaryFor(_ item: [String: Any]) -> String {
        ["rewardTitle", "clientName", "userEmail", "title", "question"]
            .compactMap { item[$0] as? String }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
