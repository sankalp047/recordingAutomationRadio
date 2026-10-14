import SwiftUI
import AppKit

// MARK: - Gate

/// Everything in the admin section sits behind this: Firebase configured,
/// signed in, and holding an admin or superadmin role.
struct AdminGate<Content: View>: View {
    let session: AdminSession
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch session.state {
        case .unconfigured:
            EmptyState(symbol: "exclamationmark.triangle",
                       title: "Admin is not set up yet",
                       message: "GoogleService-Info.plist from the funasiawe Firebase project "
                              + "needs to be added to the app bundle before the admin screens can connect.")
        case .signedOut, .failed:
            AdminLoginView(session: session)
        case .signingIn:
            ProgressView("Signing in…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .refused(let why):
            EmptyState(symbol: "person.crop.circle.badge.xmark",
                       title: "Not an admin account", message: why,
                       action: ("Sign out", { session.signOut() }))
        case .signedIn:
            content()
        }
    }
}

struct AdminLoginView: View {
    let session: AdminSession
    @State private var email = ""
    @State private var password = ""

    private var failure: String? {
        if case let .failed(m) = session.state { return m }
        return nil
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Sign in to FunAsia admin").font(.system(size: 16, weight: .medium))
            Text("Use your @funasia.net admin account. This is separate from the recording archive sign-in.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)

            VStack(spacing: 8) {
                TextField("Email", text: $email).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            }
            .frame(width: 300)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
            }

            Button("Sign in") {
                Task { await session.signIn(email: email, password: password) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty)
            .keyboardShortcut(.defaultAction)

            Text("Access is granted by role. Ask a superadmin if you cannot get in.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Dashboard

struct AdminDashboard: View {
    let session: AdminSession
    @State private var counts: [String: Int?] = [:]
    @State private var loading = true

    private let cols = [GridItem(.adaptive(minimum: 170), spacing: 13)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let r = session.role {
                    Text(r.isSuper ? "Signed in as superadmin" : "Signed in as admin")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: cols, spacing: 13) {
                    ForEach(AdminCollections.dashboardCounts, id: \.collection) { card in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(card.label).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(label(for: card.collection))
                                .font(.system(size: 26, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(15)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.secondary.opacity(0.16)))
                    }
                }
                Text("Counts include inactive records.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(22)
        }
        .task { await load() }
    }

    private func label(for collection: String) -> String {
        guard let v = counts[collection] else { return loading ? "—" : "0" }
        return v.map(String.init) ?? "0"
    }

    private func load() async {
        loading = true
        let s = session
        await withTaskGroup(of: (String, Int?).self) { group in
            for c in AdminCollections.dashboardCounts {
                group.addTask { (c.collection, await AdminRepo.count(c.collection, session: s)) }
            }
            for await (k, v) in group { counts[k] = v }
        }
        loading = false
    }
}

// MARK: - Generic editor

struct AdminCollectionView: View {
    let spec: CollectionSpec
    @State private var repo: AdminRepo
    @State private var search = ""
    @State private var editing: AdminRepo.Row?
    @State private var creating = false
    @State private var confirmDelete: AdminRepo.Row?

    init(spec: CollectionSpec, session: AdminSession) {
        self.spec = spec
        _repo = State(initialValue: AdminRepo(spec: spec, session: session))
    }

    private var filtered: [AdminRepo.Row] {
        guard !search.isEmpty else { return repo.rows }
        return repo.rows.filter {
            $0.display(spec.searchField).localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search \(spec.searchField)", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 230)
                if repo.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(repo.rows.count) \(repo.rows.count == 1 ? "record" : "records")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button { Task { await repo.load() } } label: { Image(systemName: "arrow.clockwise") }
                Button { creating = true } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()

            if let e = repo.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange).padding(14)
            }

            if repo.rows.isEmpty && !repo.loading {
                EmptyState(symbol: spec.icon, title: "Nothing here yet",
                           message: "No \(spec.title.lowercased()) have been added.",
                           action: ("Add the first one", { creating = true }))
            } else {
                List {
                    ForEach(filtered) { row in
                        HStack(spacing: 11) {
                            if let img = row.values["imageUrl"]?.asString ?? row.values["logoUrl"]?.asString,
                               !img.isEmpty, let u = URL(string: img) {
                                AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fill) }
                                    placeholder: { Color.secondary.opacity(0.12) }
                                    .frame(width: 46, height: 32).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.display(spec.searchField).isEmpty
                                     ? "(untitled)" : row.display(spec.searchField))
                                    .font(.system(size: 13, weight: .medium))
                                Text(subtitle(row)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let active = row.values["active"], !active.asBool {
                                Text("inactive").font(.system(size: 10))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.18),
                                                in: RoundedRectangle(cornerRadius: 4))
                            }
                            Button("Edit") { editing = row }.controlSize(.small)
                            Button(role: .destructive) { confirmDelete = row } label: {
                                Image(systemName: "trash")
                            }.controlSize(.small)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { await repo.load() }
        .sheet(item: $editing) { row in
            AdminEditor(spec: spec, repo: repo, row: row)
        }
        .sheet(isPresented: $creating) {
            AdminEditor(spec: spec, repo: repo, row: nil)
        }
        .alert("Delete this record?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let r = confirmDelete { Task { _ = await repo.delete(id: r.id) } }
                confirmDelete = nil
            }
        } message: {
            Text("\(confirmDelete?.display(spec.searchField) ?? "") will be removed. "
               + "Any uploaded file stays in Storage.")
        }
    }

    private func subtitle(_ row: AdminRepo.Row) -> String {
        var parts: [String] = []
        for key in ["region", "category", "type", "frequency", "regionTag", "venue"] {
            let v = row.display(key)
            if !v.isEmpty { parts.append(v) }
        }
        if spec.hasOrder { parts.append("order \(row.values["order"]?.asString ?? "0")") }
        return parts.joined(separator: " · ")
    }
}
