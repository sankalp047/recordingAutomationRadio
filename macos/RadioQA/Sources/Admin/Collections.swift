import Foundation

/// Every content collection the admin manages, transcribed from the handoff
/// (Part 2). Field names are kept exactly as documented: the website and the
/// mobile apps read them, so renaming one silently breaks a live page.
enum AdminCollections {

    static let banners = CollectionSpec(
        key: "banners", title: "Banners", icon: "rectangle.on.rectangle",
        storagePath: "banners", searchField: "title", superadminOnly: true,
        fields: [
            .init(name: "title", label: "Title", kind: .text),
            .init(name: "imageUrl", label: "Image", kind: .image, required: true,
                  help: "Seed placeholders are 1200×400"),
            .init(name: "linkUrl", label: "Link", kind: .url, required: true),
            .init(name: "order", label: "Order", kind: .number, defaultValue: .number(0)),
            .init(name: "active", label: "Active", kind: .checkbox, defaultValue: .bool(true)),
        ])

    static let stations = CollectionSpec(
        key: "stations", title: "Stations", icon: "dot.radiowaves.left.and.right",
        storagePath: "stations", searchField: "name", superadminOnly: true,
        fields: [
            .init(name: "name", label: "Name", kind: .text, required: true),
            .init(name: "frequency", label: "Frequency", kind: .text, help: "e.g. FM 104.9"),
            .init(name: "logoUrl", label: "Logo", kind: .image),
            .init(name: "streamUrl", label: "Stream URL", kind: .url, required: true),
            .init(name: "description", label: "Description", kind: .textarea),
            .init(name: "region", label: "Region", kind: .select(["us", "dubai"]), required: true),
            .init(name: "order", label: "Order", kind: .number, defaultValue: .number(0)),
            .init(name: "active", label: "Active", kind: .checkbox, defaultValue: .bool(true)),
        ])

    static let events = CollectionSpec(
        key: "events", title: "Events", icon: "calendar",
        storagePath: "events", searchField: "title", superadminOnly: true,
        fields: [
            .init(name: "title", label: "Title", kind: .text, required: true),
            .init(name: "imageUrl", label: "Image", kind: .image, required: true),
            .init(name: "videoUrl", label: "Video URL", kind: .url,
                  help: "Optional looping MP4. URL only, no uploader."),
            .init(name: "startDateTime", label: "Starts", kind: .datetimeLocal, required: true,
                  help: "YYYY-MM-DDTHH:mm, no time zone"),
            .init(name: "endDateTime", label: "Ends", kind: .datetimeLocal),
            .init(name: "venue", label: "Venue", kind: .text),
            .init(name: "descriptionShort", label: "Short description", kind: .textarea, required: true,
                  help: "2–3 sentences"),
            .init(name: "descriptionFull", label: "Full description", kind: .textarea),
            .init(name: "ticketUrl", label: "Ticket URL", kind: .url, required: true),
            .init(name: "featured", label: "Featured", kind: .checkbox, defaultValue: .bool(false),
                  help: "Stored but ignored by the website"),
            .init(name: "active", label: "Active", kind: .checkbox, defaultValue: .bool(true)),
        ])

    static let clients = CollectionSpec(
        key: "clients", title: "Clients & Partners", icon: "building.2",
        storagePath: "clients", searchField: "name", superadminOnly: true,
        fields: [
            .init(name: "name", label: "Name", kind: .text, required: true),
            .init(name: "imageUrl", label: "Logo", kind: .image, required: true),
            .init(name: "websiteUrl", label: "Website", kind: .url),
            .init(name: "order", label: "Order", kind: .number, defaultValue: .number(0)),
            .init(name: "active", label: "Active", kind: .checkbox, defaultValue: .bool(true)),
        ])

    static let clientBanners = CollectionSpec(
        key: "clientBanners", title: "Client Banners", icon: "photo.on.rectangle.angled",
        storagePath: "client-banners", searchField: "title", superadminOnly: true,
        fields: [
            .init(name: "imageUrl", label: "Desktop image", kind: .image, required: true, help: "16:9"),
            .init(name: "mobileImageUrl", label: "Mobile image", kind: .image, help: "9:16, screens ≤ 768px"),
            .init(name: "title", label: "Title", kind: .text),
            .init(name: "subtitle", label: "Subtitle", kind: .text),
            .init(name: "textPosition", label: "Text position",
                  kind: .select(["left", "center", "right"]), defaultValue: .string("left")),
            .init(name: "ctaUrl", label: "Button link", kind: .text),
            .init(name: "ctaLabel", label: "Button label", kind: .text,
                  help: "Shows “Learn More” when empty"),
            .init(name: "order", label: "Order", kind: .number, defaultValue: .number(0)),
            .init(name: "active", label: "Active", kind: .checkbox, defaultValue: .bool(true)),
        ])

    static let businesses = CollectionSpec(
        key: "businesses", title: "Businesses", icon: "storefront",
        storagePath: "businesses", searchField: "name", superadminOnly: true,
        fields: [
            .init(name: "name", label: "Name", kind: .text, required: true),
            .init(name: "category", label: "Category",
                  kind: .select(["restaurant", "entertainment", "media", "retail",
                                 "services", "events", "other"]), required: true,
                  help: "Existing data also contains capitalised values"),
            .init(name: "imageUrl", label: "Image", kind: .image),
            .init(name: "websiteUrl", label: "Website", kind: .url),
            .init(name: "descriptionShort", label: "Short description", kind: .textarea, required: true),
            .init(name: "active", label: "Active", kind: .checkbox, defaultValue: .bool(true)),
        ])

    static let rssSources = CollectionSpec(
        key: "rssSources", title: "RSS Sources", icon: "dot.radiowaves.up.forward",
        storagePath: nil, searchField: "name", superadminOnly: true,
        fields: [
            .init(name: "name", label: "Name", kind: .text, required: true, help: "e.g. NBC DFW"),
            .init(name: "url", label: "Feed URL", kind: .url, required: true),
            .init(name: "regionTag", label: "Region tag", kind: .text,
                  help: "dallas, texas and india are treated as local"),
            .init(name: "active", label: "Active", kind: .checkbox, defaultValue: .bool(true)),
        ])

    static let mediaKit = CollectionSpec(
        key: "mediaKitAssets", title: "Media Kit", icon: "doc.richtext",
        storagePath: "media-kit", searchField: "title", superadminOnly: true,
        fields: [
            .init(name: "title", label: "Title", kind: .text, required: true),
            .init(name: "fileUrl", label: "File", kind: .image, required: true,
                  help: "Image, PDF or video"),
            .init(name: "type", label: "Type",
                  kind: .select(["pdf", "image", "video", "other"]), required: true),
            .init(name: "description", label: "Description", kind: .textarea),
            .init(name: "order", label: "Order", kind: .number, defaultValue: .number(0)),
        ])

    /// Content screens driven entirely by the generic editor.
    static let content: [CollectionSpec] = [
        banners, stations, events, clients, clientBanners, businesses, rssSources, mediaKit,
    ]

    /// Dashboard cards. Counts are unfiltered, so inactive docs are included.
    static let dashboardCounts: [(label: String, collection: String)] = [
        ("Banners", "banners"), ("Stations", "stations"), ("Events", "events"),
        ("Businesses", "businesses"), ("Galleries", "galleries"), ("Podcasts", "podcasts"),
        ("RSS Sources", "rssSources"), ("Leads", "leads"),
    ]
}
