import SwiftUI

/// Moderation for user-created marketplace listings. Admins never create
/// these — they review what the public posted and what other users reported.
@MainActor
@Observable
final class MarketplaceModel {
    struct Listing: Identifiable, Equatable {
        let id: String
        var title: String
        var description: String
        var category: String
        var location: String
        var priceType: String
        var price: Double?
        var images: [String]
        var userDisplayName: String
        var active: Bool
        var flagged: Bool
        var flagReason: String
        var createdAt: String
        var expiresAt: String

        var priceLabel: String {
            switch priceType {
            case "free":     return "Free"
            case "contact":  return "Contact for price"
            default:
                guard let p = price else { return priceType.capitalized }
                let n = p == p.rounded() ? String(Int(p)) : String(format: "%.2f", p)
                return "$\(n)" + (priceType == "negotiable" ? " or near offer" : "")
            }
        }
        var isExpired: Bool {
            guard !expiresAt.isEmpty else { return false }
            return expiresAt < ISO8601DateFormatter().string(from: Date())
        }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case flagged = "Reported"
        case active  = "All active"
        var id: String { rawValue }
    }

    private let session: AdminSession
    private(set) var all: [Listing] = []
    private(set) var loading = false
    var error: String?
    var tab: Tab = .flagged

    init(session: AdminSession) { self.session = session }

    var shown: [Listing] {
        switch tab {
        case .flagged: return all.filter(\.flagged)
        case .active:  return all.filter { $0.active && !$0.flagged && !$0.isExpired }
                                 .sorted { $0.createdAt > $1.createdAt }
        }
    }
    var flaggedCount: Int { all.filter(\.flagged).count }

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
            let docs = try await FirebaseREST.list(collection: "marketplaceListings",
                                                   token: token, config: config)
            all = docs.map { d in
                Listing(id: d.id,
                        title: d.fields["title"] as? String ?? "",
                        description: d.fields["description"] as? String ?? "",
                        category: d.fields["category"] as? String ?? "",
                        location: d.fields["location"] as? String ?? "",
                        priceType: d.fields["priceType"] as? String ?? "contact",
                        price: d.fields["price"] as? Double,
                        images: (d.fields["images"] as? [Any])?.compactMap { $0 as? String } ?? [],
                        userDisplayName: d.fields["userDisplayName"] as? String ?? "Anonymous",
                        active: d.fields["active"] as? Bool ?? true,
                        flagged: d.fields["flagged"] as? Bool ?? false,
                        flagReason: d.fields["flagReason"] as? String ?? "",
                        createdAt: d.fields["createdAt"] as? String ?? "",
                        expiresAt: d.fields["expiresAt"] as? String ?? "")
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Clears the report and leaves the listing published.
    func approve(_ l: Listing) async {
        guard let (token, config) = await ready() else { return }
        do {
            try await FirebaseREST.update(path: "marketplaceListings/\(l.id)",
                                          fields: ["flagged": false, "flagReason": ""],
                                          token: token, config: config)
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func delete(_ l: Listing) async {
        guard let (token, config) = await ready() else { return }
        do {
            try await FirebaseREST.delete(path: "marketplaceListings/\(l.id)",
                                          token: token, config: config)
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct MarketplaceScreen: View {
    let session: AdminSession
    @State private var model: MarketplaceModel
    @State private var confirmDelete: MarketplaceModel.Listing?

    init(session: AdminSession) {
        self.session = session
        _model = State(initialValue: MarketplaceModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                    ForEach(MarketplaceModel.Tab.allCases) { t in
                        Text(t == .flagged && model.flaggedCount > 0
                             ? "\(t.rawValue) (\(model.flaggedCount))" : t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(model.shown.count) listing\(model.shown.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(16)
            Divider()

            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange).padding(12)
            }

            if model.shown.isEmpty && !model.loading {
                EmptyState(symbol: model.tab == .flagged ? "checkmark.shield" : "bag",
                           title: model.tab == .flagged ? "Nothing reported" : "No active listings",
                           message: model.tab == .flagged
                             ? "Listings people report appear here for review."
                             : "Nothing is currently published on the marketplace.")
            } else {
                ScrollView {
                    VStack(spacing: 9) {
                        ForEach(model.shown) { row($0) }
                    }
                    .padding(16)
                }
            }
        }
        .task { await model.load() }
        .alert("Delete this listing?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let l = confirmDelete { Task { await model.delete(l) } }
                confirmDelete = nil
            }
        } message: {
            Text("“\(confirmDelete?.title ?? "")” will be removed from the marketplace. "
               + "The seller is not notified, and the photos stay in storage.")
        }
    }

    private func row(_ l: MarketplaceModel.Listing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let first = l.images.first, let u = URL(string: first) {
                AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fill) }
                    placeholder: { Color.secondary.opacity(0.12) }
                    .frame(width: 84, height: 64).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                    .frame(width: 84, height: 64)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(l.title.isEmpty ? "(untitled)" : l.title)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if l.flagged {
                        Text("reported").font(.system(size: 10))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                    }
                    if l.isExpired {
                        Text("expired").font(.system(size: 10))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text([l.category, l.location, l.priceLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("by \(l.userDisplayName)").font(.system(size: 10)).foregroundStyle(.tertiary)
                if l.flagged && !l.flagReason.isEmpty {
                    Text("Reported for: \(l.flagReason)")
                        .font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()

            VStack(spacing: 6) {
                Button {
                    if let u = URL(string: "https://www.funasia.net/marketplace/\(l.id)") {
                        NSWorkspace.shared.open(u)
                    }
                } label: { Label("View", systemImage: "arrow.up.right.square").font(.system(size: 11)) }
                    .controlSize(.small)
                if l.flagged {
                    Button { Task { await model.approve(l) } } label: {
                        Label("Approve", systemImage: "checkmark").font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("Clear the report and leave it published")
                }
                Button(role: .destructive) { confirmDelete = l } label: {
                    Label("Delete", systemImage: "trash").font(.system(size: 11))
                }.controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(l.flagged ? Color.red.opacity(0.3) : Color.secondary.opacity(0.14)))
    }
}
