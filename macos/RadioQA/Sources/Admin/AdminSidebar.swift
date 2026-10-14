import Foundation

/// The admin sidebar exactly as the web admin has it (wiring handoff §4):
/// same order, same labels, same role gating, same BigFan grouping.
///
/// Firestore rules do NOT separate admin from superadmin for content, so the
/// app has to hide superadmin-only screens itself. A plain admin sees only
/// Dashboard, Podcasts and Audio Studio.
enum AdminArea: Hashable, Identifiable {
    case dashboard
    case collection(String)        // generic CRUD, keyed by Firestore collection
    case custom(String)            // hand-built screen
    case bigfan(String)            // BigFan screen, keyed by backend {key}

    var id: String {
        switch self {
        case .dashboard:          return "dashboard"
        case .collection(let k):  return "c.\(k)"
        case .custom(let k):      return "x.\(k)"
        case .bigfan(let k):      return "b.\(k)"
        }
    }
}

struct AdminItem: Identifiable {
    let area: AdminArea
    let title: String
    let icon: String
    let superadminOnly: Bool
    /// Why this screen cannot work yet, if it can't.
    let blockedBy: Blocker?
    var id: String { area.id }

    enum Blocker: String {
        case backend   = "Needs the admin backend deployed to funasia.net"
        case native    = "Done natively; not built yet"
        case notBuilt  = "Not built yet"
        case neverBuilt = "No page was ever built for this on the web either"
    }
    var isReady: Bool { blockedBy == nil }
}

enum AdminSidebar {

    /// Items 1–18, in the web admin's order.
    static let main: [AdminItem] = [
        .init(area: .dashboard, title: "Dashboard", icon: "square.grid.2x2",
              superadminOnly: false, blockedBy: nil),
        .init(area: .collection("banners"), title: "Banners", icon: "photo",
              superadminOnly: true, blockedBy: nil),
        .init(area: .custom("popup"), title: "Site Popup", icon: "play.rectangle",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .collection("stations"), title: "Stations", icon: "dot.radiowaves.left.and.right",
              superadminOnly: true, blockedBy: nil),
        .init(area: .collection("events"), title: "Events", icon: "calendar",
              superadminOnly: true, blockedBy: nil),
        .init(area: .custom("events-app-downloads"), title: "Events App Downloads", icon: "iphone",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .collection("clients"), title: "Clients & Partners", icon: "person.2",
              superadminOnly: true, blockedBy: nil),
        .init(area: .collection("clientBanners"), title: "Client Banners", icon: "rectangle.split.3x1",
              superadminOnly: true, blockedBy: nil),
        .init(area: .collection("bollywoodReviews"), title: "Advertising Reviews", icon: "film",
              superadminOnly: true, blockedBy: nil),
        .init(area: .collection("businesses"), title: "Businesses", icon: "building.2",
              superadminOnly: true, blockedBy: nil),
        .init(area: .custom("galleries"), title: "Galleries", icon: "camera",
              superadminOnly: true, blockedBy: .notBuilt),
        .init(area: .collection("rssSources"), title: "RSS Sources", icon: "dot.radiowaves.up.forward",
              superadminOnly: true, blockedBy: nil),
        .init(area: .collection("mediaKitAssets"), title: "Media Kit", icon: "doc.text",
              superadminOnly: true, blockedBy: nil),
        .init(area: .custom("podcasts"), title: "Podcasts", icon: "headphones",
              superadminOnly: false, blockedBy: .notBuilt),
        .init(area: .custom("audio-studio"), title: "Audio Studio", icon: "waveform",
              superadminOnly: false, blockedBy: .native),
        .init(area: .custom("marketplace"), title: "Marketplace", icon: "bag",
              superadminOnly: true, blockedBy: .notBuilt),
        .init(area: .custom("email"), title: "Email Campaigns", icon: "envelope",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .custom("inbox"), title: "Inbox", icon: "tray",
              superadminOnly: true, blockedBy: .backend),
    ]

    /// Items 19–32. Every one reads through the admin backend, because BigFan
    /// is a second Firebase project reached with its own service account.
    static let bigfan: [AdminItem] = [
        .init(area: .bigfan("analytics"), title: "Analytics", icon: "chart.bar",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("content-engagement"), title: "Content Engagement", icon: "headphones",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("stations"), title: "BigFan Stations", icon: "dot.radiowaves.left.and.right",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("featured-banners"), title: "Featured Banners", icon: "photo",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("ads"), title: "BigFan Ads", icon: "megaphone",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("rewards"), title: "Reward Offers", icon: "gift",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("reward-claims"), title: "Reward Claims", icon: "ticket",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("redeem-codes"), title: "Redeem Codes", icon: "tag",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("podcasts"), title: "BigFan Podcasts", icon: "mic",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("interviews"), title: "Interviews", icon: "bubble.left.and.bubble.right",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("trending"), title: "Trending", icon: "chart.line.uptrend.xyaxis",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("top-podcasts"), title: "Top Podcasts", icon: "trophy",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("trivia-questions"), title: "Trivia Questions", icon: "questionmark.circle",
              superadminOnly: true, blockedBy: .backend),
        .init(area: .bigfan("trivia-answers"), title: "Trivia Answers", icon: "dice",
              superadminOnly: true, blockedBy: .backend),
    ]

    /// What this role may actually see.
    static func visible(_ items: [AdminItem], role: AdminSession.Role?) -> [AdminItem] {
        guard let role else { return [] }
        return role.isSuper ? items : items.filter { !$0.superadminOnly }
    }

    static func spec(for area: AdminArea) -> CollectionSpec? {
        guard case let .collection(key) = area else { return nil }
        return AdminCollections.all.first { $0.key == key }
    }

    static var builtCount: Int {
        (main + bigfan).filter(\.isReady).count
    }
    static var totalCount: Int { main.count + bigfan.count }
}
