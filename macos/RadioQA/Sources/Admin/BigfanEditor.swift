import SwiftUI
import AppKit

/// Builds a form from a BigFan field config. Every control maps to the exact
/// JSON shape the backend validates against.
struct BigfanEditor: View {
    let model: BigfanModel
    let spec: BigfanSpec
    @State var target: BigfanCollectionView.EditTarget
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    private var isNew: Bool { target.id.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(isNew ? "New" : "Edit") \(spec.title.singularised)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(spec.fields) { f in
                        if model.visible(f, in: target.values) {
                            control(for: f)
                        }
                    }
                }
                .padding(18)
            }

            Divider()
            HStack {
                if let e = model.error {
                    Text(e).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
                }
                Spacer()
                if saving || model.uploading != nil { ProgressView().controlSize(.small) }
                Button("Save") {
                    Task {
                        saving = true
                        if await model.save(id: isNew ? nil : target.id, values: target.values) {
                            dismiss()
                        }
                        saving = false
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(saving || model.uploading != nil)
            }
            .padding(16)
        }
        .frame(width: 580, height: 660)
    }

    @ViewBuilder
    private func control(for f: BigfanField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(f.label).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if f.isRequired {
                    Text("required").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            switch f.type {
            case "textarea":
                TextEditor(text: str(f)).font(.system(size: 12)).frame(height: 68)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.3)))

            case "checkbox":
                Toggle(isOn: Binding(
                    get: { target.values[f.name] as? Bool ?? false },
                    set: { target.values[f.name] = $0 })) {
                        Text("Enabled").font(.system(size: 12))
                    }
                    .toggleStyle(.switch)

            case "number":
                TextField(f.placeholder ?? "0", text: Binding(
                    get: {
                        guard let d = target.values[f.name] as? Double else {
                            return target.values[f.name] as? String ?? ""
                        }
                        return d == d.rounded() ? String(Int(d)) : String(d)
                    },
                    // blank would be stored as 0 by the server, so always send a number
                    set: { target.values[f.name] = Double($0) ?? 0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 140)

            case "select":
                Picker("", selection: str(f)) {
                    Text("—").tag("")
                    ForEach(f.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 240)

            case "multiSelect":
                let chosen = Set(array(f))
                HStack(spacing: 7) {
                    ForEach(f.options ?? [], id: \.value) { o in
                        let on = chosen.contains(o.value)
                        Button(o.label) {
                            var next = array(f)
                            if on { next.removeAll { $0 == o.value } } else { next.append(o.value) }
                            target.values[f.name] = next
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.14),
                                    in: Capsule())
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .font(.system(size: 12))
                    }
                }

            case "stringArray":
                VStack(alignment: .leading, spacing: 3) {
                    TextField(f.placeholder ?? "comma separated", text: Binding(
                        get: { array(f).joined(separator: ", ") },
                        set: { s in
                            target.values[f.name] = s.components(separatedBy: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        }))
                        .textFieldStyle(.roundedBorder)
                    Text("Separate with commas.").font(.system(size: 10)).foregroundStyle(.secondary)
                }

            case "socialLinks":
                VStack(spacing: 5) {
                    ForEach(["facebook", "instagram", "youtube", "twitter"], id: \.self) { k in
                        HStack {
                            Text(k.capitalized).font(.system(size: 11))
                                .frame(width: 74, alignment: .leading)
                            TextField("", text: Binding(
                                get: { (target.values[f.name] as? [String: Any])?[k] as? String ?? "" },
                                set: {
                                    var m = target.values[f.name] as? [String: Any] ?? [:]
                                    if $0.isEmpty { m.removeValue(forKey: k) } else { m[k] = $0 }
                                    target.values[f.name] = m
                                }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

            case "date":
                VStack(alignment: .leading, spacing: 3) {
                    TextField("YYYY-MM-DD", text: str(f))
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                    Text("Stored as UTC midnight. Once set, a date cannot be cleared.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }

            case "datetime":
                VStack(alignment: .leading, spacing: 3) {
                    DatePicker("", selection: Binding(
                        get: { CentralTime.parse(target.values[f.name] as? String ?? "") ?? Date() },
                        set: { target.values[f.name] = CentralTime.toUTCString($0) }),
                        displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .environment(\.timeZone, CentralTime.zone)
                    Text("Entered in Dallas time (America/Chicago), stored as UTC.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }

            case "stationSelect":
                Picker("", selection: str(f)) {
                    Text("—").tag("")
                    ForEach(model.stations, id: \.id) { Text("\($0.name)").tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 260)

            case "contentSelect":
                // options come from stations or interviews, per dependsOn
                let kind = (target.values[f.dependsOn ?? "contentType"] as? String) ?? ""
                let source = kind == "interview" ? model.interviews : model.stations
                VStack(alignment: .leading, spacing: 3) {
                    Picker("", selection: str(f)) {
                        Text("—").tag("")
                        ForEach(source, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 260)
                    if kind.isEmpty {
                        Text("Pick a content type first.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

            case "image":
                HStack(spacing: 10) {
                    if let s = target.values[f.name] as? String, !s.isEmpty, let u = URL(string: s) {
                        AsyncImage(url: u) { $0.resizable().aspectRatio(contentMode: .fill) }
                            placeholder: { Color.secondary.opacity(0.12) }
                            .frame(width: 70, height: 46).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("https://…", text: str(f)).textFieldStyle(.roundedBorder)
                        Button("Choose file…") { pick(f) }
                            .controlSize(.small).disabled(model.uploading != nil)
                    }
                }

            default:   // text, url
                TextField(f.placeholder ?? "", text: str(f)).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func str(_ f: BigfanField) -> Binding<String> {
        Binding(get: { target.values[f.name] as? String ?? "" },
                set: { target.values[f.name] = $0 })
    }

    private func array(_ f: BigfanField) -> [String] {
        (target.values[f.name] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func pick(_ f: BigfanField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let link = await model.upload(url) { target.values[f.name] = link }
        }
    }
}

private extension String {
    var singularised: String {
        if hasSuffix("ies") { return String(dropLast(3)) + "y" }
        if hasSuffix("es"), !hasSuffix("ses") { return String(dropLast(2)) }
        if hasSuffix("s") { return String(dropLast()) }
        return self
    }
}
