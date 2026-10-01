import SwiftUI
import AppKit

/// The main screen. Pick a station, pick a day, pick an hour, listen or save.
/// Deliberately three plain choices in a row rather than anything clever.
struct FindScreen: View {
    let model: AppModel
    @Binding var selection: Recording?
    let downloads: Downloads

    private var station: String { model.focusedStation ?? model.stations.first ?? "" }
    private var hours: [Int] { Array(model.startHour..<model.endHour) }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            if model.recordings.isEmpty && !model.loading {
                EmptyState(symbol: "calendar.badge.exclamationmark",
                           title: "Nothing recorded on this day",
                           message: model.isToday
                             ? "Recording runs from 6 AM to midnight. Hours appear here as they finish."
                             : "No audio was saved for any station on \(model.friendlyDate).")
            } else {
                list
            }
        }
    }

    // MARK: step 1 and 2

    private var picker: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Which station?").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(model.stations, id: \.self) { st in
                        Button {
                            model.focusedStation = st
                        } label: {
                            Text(StationName.pretty(st))
                                .font(.system(size: 13, weight: station == st ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(station == st ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(station == st ? Color.white : Color.primary)
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.secondary.opacity(station == st ? 0 : 0.2)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("2. Which day?").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { model.shiftDay(-1) } label: {
                        Label("Previous", systemImage: "chevron.left").labelStyle(.iconOnly)
                    }
                    DatePicker("", selection: Binding(get: { model.date },
                                                      set: { model.date = $0 }),
                               displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden().frame(width: 128)
                        .onChange(of: model.date) { _, _ in Task { await model.load() } }
                    Button { model.shiftDay(1) } label: {
                        Label("Next", systemImage: "chevron.right").labelStyle(.iconOnly)
                    }
                    .disabled(model.isToday)
                    Text(model.friendlyDate).font(.system(size: 13, weight: .medium))
                    if !model.isToday {
                        Button("Today") { model.date = Date(); Task { await model.load() } }
                            .controlSize(.small)
                    }
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                    Button {
                        downloads.saveDay(station: station, recordings: model.recordings(for: station),
                                          day: model.dateString, model: model)
                    } label: {
                        Label("Save whole day", systemImage: "square.and.arrow.down.on.square")
                            .font(.system(size: 12))
                    }
                    .disabled(model.recordings(for: station).isEmpty)
                    .help("Save every recorded hour for this station into a folder")
                }
            }
        }
        .padding(20)
    }

    // MARK: step 3

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("3. Pick a time").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let p = downloads.progress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(p).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(hours, id: \.self) { h in row(hour: h) }
                }
                .padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
    }

    private func row(hour: Int) -> some View {
        let segs = model.segments(station: station, hour: hour)
        let frac = model.cov(station)?.coverage(forHour: hour)
        let future = model.isToday && hour > currentHour
        let health: Health = future ? .noData
            : Health.from(frac, hasData: !segs.isEmpty || (frac ?? 0) > 0)
        let playing = selection != nil && segs.contains(selection!)

        return HStack(spacing: 14) {
            Text(HourLabel.short(hour))
                .font(.system(size: 14, weight: .medium))
                .frame(width: 66, alignment: .leading)

            HStack(spacing: 7) {
                Circle().fill(health.color).frame(width: 9, height: 9)
                Text(future ? "Not yet" : health.label)
                    .font(.system(size: 12))
                    .foregroundStyle(health == .complete ? Color.primary : Color.secondary)
            }
            .frame(width: 136, alignment: .leading)

            if segs.count > 1 {
                Text("saved in \(segs.count) pieces")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let s = segs.first {
                Text(s.durationLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()

            if let first = segs.first {
                Button {
                    selection = first
                } label: {
                    Label(playing ? "Playing" : "Listen",
                          systemImage: playing ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(playing)

                Button {
                    downloads.saveOne(first, model: model)
                } label: {
                    Label("Save", systemImage: "arrow.down.circle").font(.system(size: 12))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Save this hour as an audio file")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(playing ? Color.accentColor.opacity(0.12)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(playing ? Color.accentColor.opacity(0.5) : .clear))
    }

    private var currentHour: Int {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return cal.component(.hour, from: Date())
    }
}

// MARK: - Saving audio

@MainActor
@Observable
final class Downloads {
    var progress: String?
    var lastError: String?

    func saveOne(_ rec: Recording, model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName(rec)
        panel.canCreateDirectories = true
        panel.message = "Save this hour as an MP3 file"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            progress = "Saving…"
            defer { progress = nil }
            do {
                try await model.download(rec, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func saveDay(station: String, recordings: [Recording], day: String, model: AppModel) {
        guard !recordings.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save here"
        panel.message = "Choose a folder for \(recordings.count) recordings"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        Task {
            let folder = dir.appendingPathComponent("\(StationName.pretty(station)) \(day)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var failed = 0
            for (i, rec) in recordings.enumerated() {
                progress = "Saving \(i + 1) of \(recordings.count)…"
                do { try await model.download(rec, to: folder.appendingPathComponent(suggestedName(rec))) }
                catch { failed += 1 }
            }
            progress = nil
            if failed > 0 { lastError = "\(failed) of \(recordings.count) could not be saved." }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    /// A name a person can read, not the storage key.
    private func suggestedName(_ r: Recording) -> String {
        let hour = HourLabel.short(r.startHour).replacingOccurrences(of: " ", with: "")
        return "\(StationName.pretty(r.station)) \(r.date) \(hour).mp3"
    }
}
