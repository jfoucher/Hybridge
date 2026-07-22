import SwiftUI

/// Finds nearby watches. Two roles: the full-screen first-run experience
/// (empty roster), and — with `addMode` — a sheet from My Watches for
/// adding another watch while one may already be connected.
struct ScanView: View {
    @EnvironmentObject var watch: WatchManager
    @Environment(\.dismiss) private var dismiss

    var addMode = false

    var body: some View {
        NavigationStack {
            List {
                if !addMode {
                    Section {
                        HStack {
                            Image(systemName: "applewatch.radiowaves.left.and.right")
                                .font(.largeTitle)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text("Fossil Hybrid HR")
                                    .font(.headline)
                                Text(watch.connectionState.label)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Nearby watches") {
                    Toggle("Show all devices", isOn: Binding(
                        get: { watch.scanShowsAllDevices },
                        set: { watch.setScanShowsAllDevices($0) }
                    ))
                    if watch.discovered.isEmpty {
                        Text(watch.isScanning
                             ? String(localized: "Searching… make sure the watch is not connected to another phone or the old Fossil app.")
                             : String(localized: "Tap Scan to search for your watch."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(watch.discovered) { found in
                        Button {
                            watch.connect(found.peripheral)
                            if addMode { dismiss() }
                        } label: {
                            HStack {
                                Text(found.name)
                                if watch.hasKnownWatches,
                                   WatchRegistry.shared.watch(found.id) != nil {
                                    Text("added")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                                }
                                Spacer()
                                Text("\(found.rssi) dB")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(addMode ? String(localized: "Add a watch") : "Hybridge")
            .themedList()
            .onAppear {
                if addMode || watch.connectionState == .disconnected {
                    watch.startScan()
                }
            }
            .onDisappear {
                if addMode, watch.isScanning {
                    watch.stopScan()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if watch.isScanning {
                        Button("Stop") { watch.stopScan() }
                    } else {
                        Button("Scan") { watch.startScan() }
                    }
                }
                if addMode {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }
}
