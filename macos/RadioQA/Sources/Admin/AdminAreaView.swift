import SwiftUI

/// Routes a sidebar item to its screen, or says plainly why there isn't one.
struct AdminAreaView: View {
    let area: AdminArea
    let session: AdminSession

    private var item: AdminItem? {
        (AdminSidebar.main + AdminSidebar.bigfan).first { $0.area == area }
    }

    var body: some View {
        if case .dashboard = area {
            AdminDashboard(session: session)
        } else if let spec = AdminSidebar.spec(for: area) {
            AdminCollectionView(spec: spec, session: session)
        } else if case .custom("galleries") = area {
            GalleriesScreen(session: session)
        } else if case .custom("marketplace") = area {
            MarketplaceScreen(session: session)
        } else if case .custom("podcasts") = area {
            PodcastsScreen(session: session)
        } else if case let .bigfan(key) = area, let spec = BigfanCatalog.spec(key) {
            BigfanCollectionView(spec: spec, session: session)
        } else {
            notBuilt
        }
    }

    @ViewBuilder
    private var notBuilt: some View {
        let title = item?.title ?? "This screen"
        switch item?.blockedBy {
        case .backend:
            EmptyState(
                symbol: "server.rack",
                title: "\(title) needs the backend",
                message: "This screen talks to /api/admin on funasia.net — for secrets, "
                       + "or for the BigFan project, which has its own service account. "
                       + "Those routes are written and building on the port-admin-api branch, "
                       + "but have not been merged and deployed yet.")
        case .native:
            EmptyState(
                symbol: "waveform",
                title: "\(title) is built natively",
                message: "Waveform and trim run on this Mac with AVFoundation rather than "
                       + "through the server, so no ~80 MB ffmpeg binary ships with the site. "
                       + "Not built yet.")
        case .neverBuilt:
            EmptyState(
                symbol: "questionmark.folder",
                title: "\(title) was never built",
                message: "The web admin links to this but the page returns 404. "
                       + "The data exists, so it can be added whenever you want it.")
        default:
            EmptyState(
                symbol: "hammer",
                title: "\(title) is not built yet",
                message: "It reads Firestore directly, so nothing is blocking it — "
                       + "it just has not been written.")
        }
    }
}
