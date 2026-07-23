import SwiftUI

/// Progressive-disclosure home for phone-side features used by optional
/// watch apps. Integrations remain compiled into Hybridge, but do not occupy
/// the main settings screen until the user chooses to add one.
struct IntegrationsView: View {
    @State private var homeAssistantAdded = HomeAssistantSettingsStore.isAdded
    @State private var homeAssistantEnabled = HomeAssistantSettingsStore.isEnabled

    var body: some View {
        Form {
            if homeAssistantAdded {
                Section {
                    NavigationLink {
                        HomeAssistantSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            Label("Home Assistant", systemImage: "house.and.flag")
                            Spacer()
                            Text(homeAssistantEnabled ? "Enabled" : "Disabled")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Added integrations")
                } footer: {
                    Text("Open an integration to configure, disable, or remove it.")
                }
            } else {
                Section {
                    NavigationLink {
                        HomeAssistantSettingsView(addsIntegration: true)
                    } label: {
                        Label("Home Assistant", systemImage: "house.and.flag")
                    }
                } header: {
                    Text("Available integrations")
                } footer: {
                    Text("Connect Home Assistant entities to its companion watch app.")
                }
            }
        }
        .navigationTitle("Integrations")
        .themedList()
        .onAppear(perform: refreshState)
        .onReceive(NotificationCenter.default.publisher(
            for: .homeAssistantIntegrationChanged)) { _ in
            refreshState()
        }
    }

    private func refreshState() {
        homeAssistantAdded = HomeAssistantSettingsStore.isAdded
        homeAssistantEnabled = HomeAssistantSettingsStore.isEnabled
    }
}

/// Configures the Home Assistant REST bridge and chooses the ordered entity
/// carousel exposed to homeAssistantApp.wapp.
struct HomeAssistantSettingsView: View {
    @EnvironmentObject var watch: WatchManager
    @Environment(\.dismiss) private var dismiss
    var addsIntegration = false

    // Load Keychain state once from `.task`, not in property initializers.
    // NavigationLink may construct its destination repeatedly while the
    // parent settings screen updates, which caused a Keychain lookup (and a
    // misleading log line) for nearly every BLE packet.
    @State private var address = ""
    @State private var token = ""
    @State private var selectedIDs: [String] = []
    @State private var available: [HomeAssistantEntity] = []
    @State private var loading = false
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var loadedStoredSettings = false
    @State private var integrationAdded = HomeAssistantSettingsStore.isAdded
    @State private var integrationEnabled = HomeAssistantSettingsStore.isEnabled
    @State private var allowsInsecureHTTP = false
    @State private var confirmingRemoval = false
    @State private var installingApp = false
    @FocusState private var inputFocused: Bool

    private var appInstalledOnWatch: Bool {
        watch.installedApps.contains { $0.name == "homeAssistantApp" }
    }

    private var unselected: [HomeAssistantEntity] {
        available.filter { !selectedIDs.contains($0.id) }.sorted {
            let left = sortRank($0.type), right = sortRank($1.type)
            return left == right ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                                 : left < right
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $integrationEnabled)
                    .onChange(of: integrationEnabled) { _, enabled in
                        guard integrationAdded else { return }
                        HomeAssistantSettingsStore.setEnabled(enabled)
                    }
            } footer: {
                Text("Disabling the integration keeps its credentials and entity choices, but watch requests will not contact Home Assistant.")
            }

            Section {
                if appInstalledOnWatch {
                    Label("Home Assistant app installed on watch", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                } else {
                    Button {
                        installAppOnWatch()
                    } label: {
                        HStack {
                            Label("Install Home Assistant app on watch", systemImage: "square.and.arrow.down")
                            Spacer()
                            if installingApp { ProgressView() }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(installingApp)
                }
            } footer: {
                Text("The watch app displays these entities and lets you control lights and climate from your wrist.")
            }

            Section {
                TextField("https://homeassistant.example", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                SecureField("Long-lived access token", text: $token)
                    .textContentType(.none)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        HomeAssistantLog.print("Token field submitted (length=\(token.utf8.count))")
                    }
                Text(token.isEmpty ? String(localized: "No token entered")
                                   : String(localized: "\(token.utf8.count) characters entered"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(token.isEmpty ? Theme.danger : Theme.success)
                Button {
                    HomeAssistantLog.print("Save credentials button received tap")
                    inputFocused = false
                    saveCredentialsOnly()
                } label: {
                    Label("Save credentials", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button {
                    HomeAssistantLog.print("Connect button received tap")
                    inputFocused = false
                    Task { await connectAndLoad(saveCredentials: true) }
                } label: {
                    HStack {
                        Label("Connect and load entities", systemImage: "network")
                        Spacer()
                        if loading { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(loading)
            } header: {
                Text("Connection")
            } footer: {
                Text("Use your Home Assistant base URL and a Long-Lived Access Token from the bottom of your Home Assistant profile. HTTPS protects the token and is required by default.")
            }

            Section {
                Toggle("Allow insecure local HTTP", isOn: $allowsInsecureHTTP)
                if allowsInsecureHTTP {
                    Label("Anyone able to observe your local network may capture this long-lived token. Never enable this for a public or remote host.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }
            } header: {
                Text("Advanced transport")
            }

            if let status {
                Section {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                }
            }

            if !selectedIDs.isEmpty {
                Section {
                    ForEach(selectedIDs, id: \.self) { id in
                        entityRow(entity(for: id), fallbackID: id)
                    }
                    .onDelete(perform: removeSelected)
                    .onMove(perform: moveSelected)
                } header: {
                    Text("On the watch (\(selectedIDs.count)/\(HomeAssistantSettingsStore.maximumEntities))")
                } footer: {
                    Text("Home occupies the 3 o’clock slot. This order fills the remaining slots clockwise. Swipe to remove or drag to reorder.")
                }
            }

            if !unselected.isEmpty {
                Section {
                    ForEach(unselected) { entity in
                        Button {
                            add(entity.id)
                        } label: {
                            HStack {
                                entityLabel(entity)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .foregroundStyle(Theme.ink)
                        .disabled(selectedIDs.count >= HomeAssistantSettingsStore.maximumEntities)
                    }
                } header: {
                    Text("Available entities")
                } footer: {
                    Text("Lights expose power and brightness; climate entities expose mode and target temperature. Other domains are shown read-only on the watch.")
                }
            }

            if integrationAdded {
                Section {
                    Button("Remove Home Assistant integration", role: .destructive) {
                        confirmingRemoval = true
                    }
                }
            }
        }
        .navigationTitle("Home Assistant")
        .themedList()
        .tint(Theme.accent)
        .task {
            guard !loadedStoredSettings else { return }
            loadedStoredSettings = true
            if addsIntegration {
                HomeAssistantSettingsStore.addIntegration()
            }
            integrationAdded = HomeAssistantSettingsStore.isAdded
            integrationEnabled = HomeAssistantSettingsStore.isEnabled
            address = HomeAssistantSettingsStore.address
            token = HomeAssistantCredentialStore.loadToken() ?? ""
            selectedIDs = HomeAssistantSettingsStore.selectedEntityIDs
            allowsInsecureHTTP = HomeAssistantSettingsStore.allowsInsecureHTTP
            HomeAssistantLog.print("Settings opened: address=\(!address.isEmpty), token=\(!token.isEmpty), selected=\(selectedIDs.count)")
            guard !address.isEmpty, !token.isEmpty else { return }
            await connectAndLoad(saveCredentials: false)
        }
        .confirmationDialog("Remove Home Assistant?", isPresented: $confirmingRemoval,
                            titleVisibility: .visible) {
            Button("Remove integration", role: .destructive, action: removeIntegration)
        } message: {
            Text("This removes the server address, selected entities, and access token from this iPhone.")
        }
    }

    @ViewBuilder
    private func entityRow(_ entity: HomeAssistantEntity?, fallbackID: String) -> some View {
        if let entity {
            entityLabel(entity)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(fallbackID)
                Text("Not returned by Home Assistant")
                    .font(.caption).foregroundStyle(Theme.sub)
            }
        }
    }

    private func entityLabel(_ entity: HomeAssistantEntity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entity.name)
            Text("\(entity.type) · \(entity.state)")
                .font(.caption).foregroundStyle(Theme.sub)
        }
    }

    private func entity(for id: String) -> HomeAssistantEntity? {
        available.first { $0.id == id }
    }

    private func sortRank(_ type: String) -> Int {
        switch type {
        case "light": return 0
        case "climate": return 1
        default: return 2
        }
    }

    private func add(_ id: String) {
        guard selectedIDs.count < HomeAssistantSettingsStore.maximumEntities,
              !selectedIDs.contains(id) else { return }
        selectedIDs.append(id)
        persistSelection()
    }

    private func removeSelected(at offsets: IndexSet) {
        selectedIDs.remove(atOffsets: offsets)
        persistSelection()
    }

    private func moveSelected(from source: IndexSet, to destination: Int) {
        selectedIDs.move(fromOffsets: source, toOffset: destination)
        persistSelection()
    }

    private func persistSelection() {
        HomeAssistantSettingsStore.selectedEntityIDs = selectedIDs
    }

    private func saveCredentialsOnly() {
        HomeAssistantLog.print("Explicit credential save tapped: addressLength=\(address.count), tokenLength=\(token.utf8.count)")
        status = nil
        errorMessage = nil
        do {
            let configuration = try HomeAssistantSettingsStore.configuration(
                address: address, token: token, selectedEntityIDs: selectedIDs,
                allowsInsecureHTTP: allowsInsecureHTTP)
            try persistCredentials(configuration)
            status = String(localized: "Credentials saved")
        } catch {
            errorMessage = error.localizedDescription
            HomeAssistantLog.print("Explicit credential save failed: \(error.localizedDescription)")
        }
    }

    private func persistCredentials(_ configuration: HomeAssistantConfiguration) throws {
        address = configuration.baseURL.absoluteString
        guard HomeAssistantCredentialStore.saveToken(configuration.token),
              HomeAssistantCredentialStore.loadToken() == configuration.token else {
            throw HomeAssistantError.credentialSaveFailed
        }
        HomeAssistantSettingsStore.address = address
        HomeAssistantSettingsStore.allowsInsecureHTTP = allowsInsecureHTTP
        persistSelection()
        HomeAssistantLog.print("Settings credentials saved and verified for \(address)")
    }

    @MainActor
    private func connectAndLoad(saveCredentials: Bool) async {
        guard !loading else { return }
        HomeAssistantLog.print("Settings action started: save=\(saveCredentials), addressLength=\(address.count), tokenLength=\(token.utf8.count), selected=\(selectedIDs.count)")
        loading = true
        errorMessage = nil
        status = nil
        defer { loading = false }
        do {
            let configuration = try HomeAssistantSettingsStore.configuration(
                address: address, token: token, selectedEntityIDs: selectedIDs,
                allowsInsecureHTTP: allowsInsecureHTTP)
            address = configuration.baseURL.absoluteString
            if saveCredentials {
                try persistCredentials(configuration)
                status = String(localized: "Credentials saved · contacting Home Assistant…")
            }
            let entities = try await HomeAssistantAPI.shared.fetchAll(configuration: configuration)
            available = entities
            status = String(localized: "Connected · \(entities.count) entities")
            HomeAssistantLog.print("Settings connection succeeded with \(entities.count) entities")
        } catch {
            errorMessage = error.localizedDescription
            HomeAssistantLog.print("Settings action failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func installAppOnWatch() {
        guard !installingApp else { return }
        installingApp = true
        errorMessage = nil
        Task {
            do {
                try await watch.installHomeAssistantApp()
                installingApp = false
                ToastCenter.shared.success(String(localized: "Home Assistant app installed"))
            } catch {
                installingApp = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeIntegration() {
        HomeAssistantSettingsStore.removeIntegration()
        address = ""
        token = ""
        selectedIDs = []
        allowsInsecureHTTP = false
        available = []
        status = nil
        errorMessage = nil
        integrationAdded = false
        integrationEnabled = false
        dismiss()
    }
}
