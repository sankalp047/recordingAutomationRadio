import SwiftUI

/// Deliberately small. There is nothing here a person has to get right: the
/// server address is already correct, and sign-in is handled by Cloudflare.
struct SettingsView: View {
    let model: AppModel
    let auth: Auth
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings").font(.system(size: 16, weight: .semibold))
                Text("This app can only listen to and save recordings. It cannot change or delete anything.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Account").font(.system(size: 12, weight: .medium))
                if auth.signedIn, let id = auth.identity {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill.badge.checkmark")
                            .foregroundStyle(.green)
                        Text(id.display).font(.system(size: 13))
                        Spacer()
                        Button("Sign out") { Task { await auth.signOut() } }
                            .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Not signed in. Close this window and choose Sign in.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server address").font(.system(size: 11, weight: .medium))
                    TextField("https://radio-api.funasia.net", text: $url)
                        .textFieldStyle(.roundedBorder)
                    Text("Only change this if you were told to.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let r = result {
                        Label(r, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(ok ? Color.green : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Check connection") { Task { await test() } }
                        .controlSize(.small).disabled(testing || url.isEmpty)
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12))

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Done") {
                    model.baseURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(); dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(url.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460, height: 350)
        .onAppear { url = model.baseURL }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let s = try await APIClient(baseURL: url.trimmingCharacters(in: .whitespacesAndNewlines))
                .stations()
            ok = true; result = "Connected. \(s.stations.count) stations found."
        } catch {
            ok = false
            result = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
