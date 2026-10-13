import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One editor for every content collection, driven by the field list.
struct AdminEditor: View {
    let spec: CollectionSpec
    let repo: AdminRepo
    let row: AdminRepo.Row?
    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: FieldValue] = [:]
    @State private var saving = false
    @State private var uploading: String?
    @State private var problems: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(row == nil ? "New \(singular)" : "Edit \(singular)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(spec.fields) { field in
                        fieldView(field)
                    }
                }
                .padding(18)
            }

            if !problems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(problems, id: \.self) { p in
                        Label(p, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
            }

            Divider()
            HStack {
                if let e = repo.error {
                    Text(e).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || uploading != nil)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .onAppear(perform: seed)
    }

    private var singular: String {
        var t = spec.title
        if t.hasSuffix("ies") { t = String(t.dropLast(3)) + "y" }
        else if t.hasSuffix("es") && !t.hasSuffix("ses") { t = String(t.dropLast(2)) }
        else if t.hasSuffix("s") { t = String(t.dropLast()) }
        return t.lowercased()
    }

    private func seed() {
        var v: [String: FieldValue] = [:]
        for f in spec.fields {
            v[f.name] = row?.values[f.name] ?? f.defaultValue
        }
        values = v
    }

    @ViewBuilder
    private func fieldView(_ f: FieldConfig) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(f.label).font(.system(size: 12, weight: .medium))
                if f.required { Text("required").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            switch f.kind {
            case .text, .url, .datetimeLocal:
                TextField(placeholder(f), text: binding(f)).textFieldStyle(.roundedBorder)
            case .textarea:
                TextEditor(text: binding(f))
                    .font(.system(size: 12)).frame(height: 72)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.3)))
            case .number:
                TextField("0", text: binding(f)).textFieldStyle(.roundedBorder).frame(width: 110)
            case .checkbox:
                Toggle(isOn: Binding(
                    get: { values[f.name]?.asBool ?? false },
                    set: { values[f.name] = .bool($0) })) { Text("Enabled").font(.system(size: 12)) }
                    .toggleStyle(.switch)
            case .select(let options):
                Picker("", selection: Binding(
                    get: { values[f.name]?.asString ?? "" },
                    set: { values[f.name] = .string($0) })) {
                        Text("—").tag("")
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 200)
            case .image:
                imageField(f)
            }
            if let h = f.help {
                Text(h).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func imageField(_ f: FieldConfig) -> some View {
        let current = values[f.name]?.asString ?? ""
        HStack(spacing: 10) {
            if !current.isEmpty, let u = URL(string: current) {
                AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fill) }
                    placeholder: { Color.secondary.opacity(0.12) }
                    .frame(width: 70, height: 46).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            VStack(alignment: .leading, spacing: 5) {
                TextField("https://…", text: binding(f)).textFieldStyle(.roundedBorder)
                HStack(spacing: 7) {
                    Button(spec.storagePath == nil ? "No uploads for this collection" : "Choose file…") {
                        pick(f)
                    }
                    .controlSize(.small)
                    .disabled(spec.storagePath == nil || uploading != nil)
                    if uploading == f.name {
                        ProgressView().controlSize(.small)
                        Text("Uploading…").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func pick(_ f: FieldConfig) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            uploading = f.name
            defer { uploading = nil }
            if let link = await repo.upload(url) { values[f.name] = .string(link) }
        }
    }

    private func placeholder(_ f: FieldConfig) -> String {
        switch f.kind {
        case .url:           return "https://…"
        case .datetimeLocal: return "2026-10-13T19:30"
        default:             return ""
        }
    }

    private func binding(_ f: FieldConfig) -> Binding<String> {
        Binding(get: { values[f.name]?.asString ?? "" },
                set: { s in
                    values[f.name] = f.kind == .number ? .number(Double(s) ?? 0) : .string(s)
                })
    }

    /// The web never enforced required fields; the handoff calls that a bug,
    /// so they are enforced here.
    private func save() async {
        problems = spec.fields
            .filter { $0.required && (values[$0.name]?.asString ?? "").isEmpty }
            .map { "\($0.label) is required." }
        guard problems.isEmpty else { return }
        saving = true
        defer { saving = false }
        if await repo.save(id: row?.id, values: values) { dismiss() }
    }
}
