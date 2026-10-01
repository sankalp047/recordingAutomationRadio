import SwiftUI

/// The PM Radio Logs mark. Falls back to a system symbol so the app still
/// builds and runs before the artwork has been added to Resources.
struct BrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        if let img = NSImage(named: "Logo") ?? bundledLogo() {
            Image(nsImage: img)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: size * 0.7))
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
        }
    }

    private func bundledLogo() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct BrandHeader: View {
    var subtitle: String?
    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("PM Radio Logs").font(.system(size: 14, weight: .semibold))
                if let s = subtitle {
                    Text(s).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
