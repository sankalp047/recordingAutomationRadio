import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Photo albums. A custom screen rather than the generic editor, because
/// `images` is an ordered array of `{url, caption}` with multi-upload.
@MainActor
@Observable
final class GalleriesModel {
    struct Album: Identifiable, Equatable {
        var id: String
        var eventTitle: String
        var date: String              // "YYYY-MM-DD"
        var coverImageUrl: String
        var images: [Photo]
        struct Photo: Identifiable, Equatable {
            var url: String
            var caption: String
            var id: String { url }
        }
    }

    private let session: AdminSession
    private(set) var albums: [Album] = []
    private(set) var loading = false
    var error: String?
    var uploading: String?

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
            let docs = try await FirebaseREST.list(collection: "galleries", token: token, config: config)
            albums = docs.map { d in
                // The web admin crashes opening an album with no images array;
                // treat a missing array as empty instead.
                let raw = d.fields["images"] as? [Any] ?? []
                let photos = raw.compactMap { item -> Album.Photo? in
                    guard let m = item as? [String: Any] else { return nil }
                    guard let url = m["url"] as? String, !url.isEmpty else { return nil }
                    return .init(url: url, caption: m["caption"] as? String ?? "")
                }
                return Album(id: d.id,
                             eventTitle: d.fields["eventTitle"] as? String ?? "",
                             date: d.fields["date"] as? String ?? "",
                             coverImageUrl: d.fields["coverImageUrl"] as? String ?? "",
                             images: photos)
            }
            .sorted { $0.date > $1.date }     // newest album first
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func save(_ album: Album) async -> Bool {
        error = nil
        guard !album.eventTitle.trimmingCharacters(in: .whitespaces).isEmpty,
              !album.date.isEmpty else {
            error = "Title and date are required."
            return false
        }
        guard let (token, config) = await ready() else { return false }
        var cover = album.coverImageUrl
        if cover.isEmpty { cover = album.images.first?.url ?? "" }
        let payload: [String: Any] = [
            "eventTitle": album.eventTitle,
            "date": album.date,
            "coverImageUrl": cover,
            "images": album.images.map { ["url": $0.url, "caption": $0.caption] as [String: Any] },
        ]
        do {
            if album.id.isEmpty {
                try await FirebaseREST.create(collection: "galleries", fields: payload,
                                              token: token, config: config)
            } else {
                try await FirebaseREST.update(path: "galleries/\(album.id)", fields: payload,
                                              token: token, config: config)
            }
            await load()
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func delete(_ album: Album) async {
        guard let (token, config) = await ready() else { return }
        do {
            try await FirebaseREST.delete(path: "galleries/\(album.id)", token: token, config: config)
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Uploads to `galleries/{albumId}/{ms}_{name}`. The web admin writes a
    /// single path segment, which the Storage rules deny outright — so every
    /// gallery upload on the web currently fails. Two segments is correct.
    func upload(files: [URL], albumId: String) async -> [Album.Photo] {
        guard let (token, config) = await ready() else { return [] }
        let folder = albumId.isEmpty ? "new-\(Int(Date().timeIntervalSince1970))" : albumId
        var added: [Album.Photo] = []
        for (i, f) in files.enumerated() {
            uploading = "Uploading \(i + 1) of \(files.count)…"
            guard let data = try? Data(contentsOf: f) else { continue }
            let type = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            let path = "galleries/\(folder)/\(Int(Date().timeIntervalSince1970 * 1000))_\(f.lastPathComponent)"
            // A failed file is skipped, as on the web, rather than aborting the batch.
            if let url = try? await FirebaseREST.upload(data: data, to: path, contentType: type,
                                                        token: token, config: config) {
                added.append(.init(url: url, caption: ""))
            }
        }
        uploading = nil
        return added
    }
}

struct GalleriesScreen: View {
    let session: AdminSession
    @State private var model: GalleriesModel
    @State private var editing: GalleriesModel.Album?
    @State private var confirmDelete: GalleriesModel.Album?

    init(session: AdminSession) {
        self.session = session
        _model = State(initialValue: GalleriesModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Photo albums shown on the website’s gallery page.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(model.albums.count) album\(model.albums.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                Button {
                    editing = .init(id: "", eventTitle: "", date: todayString(),
                                    coverImageUrl: "", images: [])
                } label: { Label("New album", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()

            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange).padding(12)
            }

            if model.albums.isEmpty && !model.loading {
                EmptyState(symbol: "camera", title: "No albums yet",
                           message: "Albums you add here appear on the website’s gallery page.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(model.albums) { album in
                            card(album)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task { await model.load() }
        .sheet(item: $editing) { album in
            GalleryEditor(model: model, album: album)
        }
        .alert("Delete this album?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let a = confirmDelete { Task { await model.delete(a) } }
                confirmDelete = nil
            }
        } message: {
            Text("“\(confirmDelete?.eventTitle ?? "")” will be removed from the website. "
               + "The photo files stay in storage.")
        }
    }

    private func card(_ album: GalleriesModel.Album) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.secondary.opacity(0.12)
                if let u = URL(string: album.coverImageUrl.isEmpty
                               ? (album.images.first?.url ?? "") : album.coverImageUrl) {
                    AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fill) }
                        placeholder: { ProgressView().controlSize(.small) }
                }
            }
            .frame(height: 124).clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(album.eventTitle.isEmpty ? "(untitled)" : album.eventTitle)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(album.date) · \(album.images.count) photo\(album.images.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Button("Edit") { editing = album }.controlSize(.small)
                    Button(role: .destructive) { confirmDelete = album } label: {
                        Image(systemName: "trash")
                    }.controlSize(.small)
                }
                .padding(.top, 3)
            }
            .padding(11)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.16)))
    }

    private func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

struct GalleryEditor: View {
    let model: GalleriesModel
    @State var album: GalleriesModel.Album
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(album.id.isEmpty ? "New album" : "Edit album")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Title", required: true) {
                        TextField("e.g. Diwali Mela 2026", text: $album.eventTitle)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Date", required: true) {
                        TextField("YYYY-MM-DD", text: $album.date)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                    }
                    field("Cover image URL", required: false) {
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("defaults to the first photo", text: $album.coverImageUrl)
                                .textFieldStyle(.roundedBorder)
                            Text("Leave empty to use the first photo.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Photos (\(album.images.count))")
                            .font(.system(size: 12, weight: .medium))
                        if let u = model.uploading {
                            ProgressView().controlSize(.small)
                            Text(u).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add photos…") { pick() }.controlSize(.small)
                    }

                    if album.images.isEmpty {
                        Text("No photos yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                            ForEach(album.images) { photo in
                                ZStack(alignment: .topTrailing) {
                                    AsyncImage(url: URL(string: photo.url)) {
                                        $0.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: { Color.secondary.opacity(0.12) }
                                    .frame(width: 96, height: 72).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Button {
                                        album.images.removeAll { $0.url == photo.url }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain).padding(3)
                                }
                            }
                        }
                        Text("Removing a photo takes it off the website. The file stays in storage.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
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
                    Task {
                        saving = true
                        if await model.save(album) { dismiss() }
                        saving = false
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(saving || model.uploading != nil)
            }
            .padding(16)
        }
        .frame(width: 580, height: 620)
    }

    @ViewBuilder
    private func field<C: View>(_ label: String, required: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium))
                if required { Text("required").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task {
            let added = await model.upload(files: urls, albumId: album.id)
            album.images.append(contentsOf: added)
            if album.coverImageUrl.isEmpty { album.coverImageUrl = album.images.first?.url ?? "" }
        }
    }
}
