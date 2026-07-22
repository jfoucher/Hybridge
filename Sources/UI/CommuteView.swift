import SwiftUI
import MapKit

/// Edit the commuteApp destination list (`commuteApp._.config.destinations`).
/// Destinations with a location get a live MapKit ETA on the watch when
/// picked; plain names just show "On your way to …".
struct CommuteView: View {
    @EnvironmentObject var watch: WatchManager
    @State private var items: [CommuteDestination] = CommuteStore.items
    @State private var newDestination = ""
    @State private var locating: CommuteDestination?
    @State private var pushTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                ForEach($items) { $item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            if item.hasCoordinates {
                                Text("Live ETA · \(transportTitle(item.transport))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("No location — static reply")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            locating = item
                        } label: {
                            Image(systemName: item.hasCoordinates ? "mappin.circle.fill" : "mappin.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { offsets in items.remove(atOffsets: offsets) }
                .onMove { source, dest in items.move(fromOffsets: source, toOffset: dest) }

                HStack {
                    TextField("Add destination", text: $newDestination)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(trimmedNew.isEmpty)
                }
            } header: {
                Text("Destinations")
            } footer: {
                Text("Changes are saved and sent automatically. Tap the pin to attach a location and travel mode — the watch then shows a live ETA when you pick the destination.")
            }
        }
        .navigationTitle("Commute")
        .themedList()
        .toolbar { EditButton() }
        .onReceive(NotificationCenter.default.publisher(for: .activeWatchChanged)) { _ in
            items = CommuteStore.items
        }
        .onChange(of: items) { _, _ in persistAndSchedulePush() }
        .sheet(item: $locating) { destination in
            DestinationLocationPicker(destination: destination) { updated in
                if let index = items.firstIndex(where: { $0.id == updated.id }) {
                    items[index] = updated
                }
            }
        }
    }

    private func transportTitle(_ raw: String) -> String {
        switch raw {
        case "walk": return String(localized: "walking")
        case "transit": return String(localized: "transit")
        default: return String(localized: "driving")
        }
    }

    private var trimmedNew: String {
        newDestination.trimmingCharacters(in: .whitespaces)
    }

    private func add() {
        let name = trimmedNew
        guard !name.isEmpty else { return }
        items.append(CommuteDestination(name: name))
        newDestination = ""
    }

    private func persistAndSchedulePush() {
        CommuteStore.items = items
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  WatchRegistry.activeKindSync().hasCommute,
                  watch.connectionState == .ready, watch.isAuthenticated else { return }
            do {
                try await watch.pushCommuteDestinations()
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
}

/// Search for a place (MKLocalSearch) and pick the travel mode for one
/// commute destination.
private struct DestinationLocationPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State var destination: CommuteDestination
    let onSave: (CommuteDestination) -> Void

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Travel mode") {
                    Picker("Mode", selection: $destination.transport) {
                        Text("Driving").tag("car")
                        Text("Walking").tag("walk")
                        Text("Transit").tag("transit")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    HStack {
                        TextField("Search address or place", text: $query)
                            .onSubmit(search)
                        if searching { ProgressView() }
                    }
                    ForEach(results, id: \.self) { item in
                        Button {
                            destination.latitude = item.placemark.coordinate.latitude
                            destination.longitude = item.placemark.coordinate.longitude
                            onSave(destination)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? String(localized: "Unnamed place"))
                                Text(item.placemark.title ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Location for \"\(destination.name)\"")
                }

                if destination.hasCoordinates {
                    Section {
                        Button("Remove location", role: .destructive) {
                            destination.latitude = nil
                            destination.longitude = nil
                            onSave(destination)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Location")
            .themedList()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onSave(destination)
                        dismiss()
                    }
                }
            }
        }
    }

    private func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                results = response?.mapItems ?? []
                searching = false
            }
        }
    }
}
