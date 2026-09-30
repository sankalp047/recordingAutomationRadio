import SwiftUI

struct SettingsView: View {
    let model: AppModel
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.system(size: 15, weight: .medium))

            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL").font(.system(size: 12, weight: .medium))
                TextField("https://radio-api.funasia.net", text: $url)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API token").font(.system(size: 12, weight: .medium))
                SecureField("Bearer token", text: $token)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in your Keychain, never on disk in the clear.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if let r = result {
                Label(r, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ok ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Button("Test connection") { Task { await test() } }
                    .disabled(testing || url.isEmpty || token.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.baseURL = url.trimmingCharacters(in: .whitespaces)
                    model.token = token.trimmingCharacters(in: .whitespaces)
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || token.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 300)
        .onAppear { url = model.baseURL; token = model.token }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let c = APIClient(baseURL: url.trimmingCharacters(in: .whitespaces),
                          token: token.trimmingCharacters(in: .whitespaces))
        do {
            let s = try await c.stations()
            ok = true
            result = "Connected — \(s.stations.count) stations, \(s.qaProfile.bitrateKbps) kbps \(s.qaProfile.codec)"
        } catch {
            ok = false
            result = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
