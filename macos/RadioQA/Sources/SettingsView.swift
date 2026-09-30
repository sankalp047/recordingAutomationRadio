import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let auth: Auth
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings").font(.system(size: 16, weight: .semibold))
                Text("This app only reads recordings. Nothing here can change or delete them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Server address").font(.system(size: 12, weight: .medium))
                TextField("https://radio-api.funasia.net", text: $url)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Access key").font(.system(size: 12, weight: .medium))
                SecureField("Paste the key you were given", text: $token)
                    .textFieldStyle(.roundedBorder)
                Text("Kept in your Mac's Keychain. Type or paste it here — it cannot be installed from a terminal.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let r = result {
                Label(r, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ok ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if auth.signedIn, let id = auth.identity {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill.badge.checkmark")
                        .foregroundStyle(.green)
                    Text("Signed in as \(id.display)").font(.system(size: 12))
                    Spacer()
                    Button("Sign out") { Task { await auth.signOut() } }
                        .controlSize(.small)
                }
            }

            Spacer()

            HStack {
                Button("Check connection") { Task { await test() } }
                    .disabled(testing || url.isEmpty || token.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.baseURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || token.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500, height: auth.signedIn ? 420 : 370)
        .onAppear { url = model.baseURL; token = model.token }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let c = APIClient(baseURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
                          token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let s = try await c.stations()
            ok = true
            result = "Connected. \(s.stations.count) stations found."
        } catch {
            ok = false
            result = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
