import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The single site popup. Its Firestore docs are locked to `if false`, so
/// everything goes through the backend; only the image is uploaded directly.
@MainActor
@Observable
final class PopupModel {
    var enabled = false
    var imageUrl = ""
    var linkUrl = ""
    var title = ""
    var durationSeconds = 5.0
    private(set) var version = 0
    private(set) var updatedAt = ""

    private(set) var loading = false
    var saving = false
    var error: String?
    var saved = false
    var uploading = false

    private let session: AdminSession
    init(session: AdminSession) { self.session = session }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await AdminAPI.call("GET", "api/admin/popup", session: session)
            guard let c = r["config"] as? [String: Any] else { return }
            enabled = c["enabled"] as? Bool ?? false
            imageUrl = c["imageUrl"] as? String ?? ""
            linkUrl = c["linkUrl"] as? String ?? ""
            title = c["title"] as? String ?? ""
            durationSeconds = c["durationSeconds"] as? Double ?? 5
            version = Int(c["version"] as? Double ?? 0)
            updatedAt = c["updatedAt"] as? String ?? ""
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Server rules: enabling needs an image, the link must be http(s), and
    /// every save bumps the version so returning visitors see it again.
    func save() async {
        error = nil; saved = false
        if enabled && imageUrl.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "Add an image before switching the popup on."
            return
        }
        if !linkUrl.isEmpty, !(linkUrl.hasPrefix("http://") || linkUrl.hasPrefix("https://")) {
            error = "The link must start with http:// or https://"
            return
        }
        if durationSeconds < 1 || durationSeconds > 30 {
            error = "Duration must be between 1 and 30 seconds."
            return
        }
        saving = true
        defer { saving = false }
        do {
            let r = try await AdminAPI.call("POST", "api/admin/popup", body: [
                "enabled": enabled, "imageUrl": imageUrl, "linkUrl": linkUrl,
                "title": title, "durationSeconds": Int(durationSeconds),
            ], session: session)
            if let c = r["config"] as? [String: Any] {
                version = Int(c["version"] as? Double ?? Double(version))
                updatedAt = c["updatedAt"] as? String ?? updatedAt
            }
            saved = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func upload(_ url: URL) async {
        guard let config = session.firebaseConfig, let token = await session.validToken(),
              let data = try? Data(contentsOf: url) else { return }
        uploading = true
        defer { uploading = false }
        let path = "popups/\(Int(Date().timeIntervalSince1970 * 1000))_\(url.lastPathComponent)"
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        if let link = try? await FirebaseREST.upload(data: data, to: path, contentType: type,
                                                     token: token, config: config) {
            imageUrl = link
        } else {
            error = "Upload failed. If the storage rules now require the admin claim, sign out and back in."
        }
    }
}

struct PopupScreen: View {
    let session: AdminSession
    @State private var model: PopupModel

    init(session: AdminSession) {
        self.session = session
        _model = State(initialValue: PopupModel(session: session))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let e = model.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.saved {
                    Label("Saved. Everyone sees the popup again, because saving raises its version.",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.green)
                }

                Toggle(isOn: Binding(get: { model.enabled }, set: { model.enabled = $0 })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show the popup").font(.system(size: 13, weight: .medium))
                        Text("Visitors see it once per version.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                field("Image", help: "Required when the popup is on.") {
                    HStack(spacing: 10) {
                        if !model.imageUrl.isEmpty, let u = URL(string: model.imageUrl) {
                            AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fit) }
                                placeholder: { Color.secondary.opacity(0.12) }
                                .frame(width: 120, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            TextField("https://…", text: Binding(
                                get: { model.imageUrl }, set: { model.imageUrl = $0 }))
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: 7) {
                                Button("Choose file…") { pick() }
                                    .controlSize(.small).disabled(model.uploading)
                                if model.uploading { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                }

                field("Title", help: nil) {
                    TextField("", text: Binding(get: { model.title }, set: { model.title = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                field("Link", help: "Where clicking the popup goes. Must start with http:// or https://") {
                    TextField("https://…", text: Binding(
                        get: { model.linkUrl }, set: { model.linkUrl = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                field("Seconds on screen", help: "Between 1 and 30.") {
                    HStack {
                        Slider(value: Binding(get: { model.durationSeconds },
                                              set: { model.durationSeconds = $0 }),
                               in: 1...30, step: 1).frame(width: 240)
                        Text("\(Int(model.durationSeconds))s")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                HStack {
                    Button("Save") { Task { await model.save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.saving || model.loading)
                    if model.saving || model.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    if model.version > 0 {
                        Text("Version \(model.version)\(model.updatedAt.isEmpty ? "" : " · updated \(CentralTime.display(model.updatedAt))")")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                Label("The popup is configured here, but the live site does not render it yet — "
                    + "2.0 has no /api/popup route or popup component.",
                      systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private func field<C: View>(_ label: String, help: String?, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .medium))
            c()
            if let h = help { Text(h).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { await model.upload(u) }
    }
}

// MARK: - Events App Downloads

/// Read-only report: who filled in the "download the app" form, cross-matched
/// against BigFan accounts so you can see who actually signed up.
struct EventsDownloadsScreen: View {
    let session: AdminSession
    @State private var total = 0
    @State private var matched: [[String: Any]] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(16)
            Divider()

            if let e = error {
                EmptyState(symbol: "exclamationmark.triangle", title: "Could not load", message: e,
                           action: ("Try again", { Task { await load() } }))
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(matched.count) confirmed download\(matched.count == 1 ? "" : "s") "
                       + "out of \(total) form submission\(total == 1 ? "" : "s")")
                        .font(.system(size: 15, weight: .semibold))
                    Text("“Confirmed” means the email that filled in the form also has a BigFan account.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    if matched.isEmpty {
                        EmptyState(symbol: "iphone", title: "No confirmed downloads",
                                   message: "Nobody who filled in the form has created a BigFan account yet.")
                    } else {
                        List(Array(matched.enumerated()), id: \.offset) { _, m in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m["name"] as? String ?? "—")
                                        .font(.system(size: 13, weight: .medium))
                                    Text(m["email"] as? String ?? "")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(CentralTime.displayDate(m["dateJoined"] as? String ?? ""))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .listStyle(.inset)
                    }
                }
                .padding(20)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await AdminAPI.call("GET", "api/admin/events-app-downloads", session: session)
            total = Int(r["totalFormSubmissions"] as? Double ?? 0)
            matched = r["matched"] as? [[String: Any]] ?? []
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
