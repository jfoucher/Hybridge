import SwiftUI

/// Editor for the custom on-watch menu (rendered by the open-source
/// watchface; pushed as customWatchFace._.config.menu_structure). One button
/// event opens the menu; inside it, each item binds to a button slot.
struct MenuView: View {
    @EnvironmentObject var watch: WatchManager
    @State private var enabled = MenuStore.isEnabled
    @State private var title = MenuStore.title
    @State private var openSlot = MenuStore.openSlot
    @State private var items = MenuStore.items
    @State private var pushTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Toggle("Enable custom menu", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        MenuStore.isEnabled = newValue
                        schedulePush()
                    }
            } footer: {
                Text("Experimental. Works on faces built with this app. Pushed automatically on connect.")
            }

            if enabled {
                Section("Menu") {
                    TextField("Title", text: $title)
                        .onChange(of: title) { _, newValue in
                            MenuStore.title = newValue
                            schedulePush()
                        }
                    Picker("Opens with", selection: $openSlot) {
                        ForEach(WatchMenuItem.slots, id: \.action) { slot in
                            Text(slot.title).tag(slot.action)
                        }
                    }
                    .onChange(of: openSlot) { _, newValue in
                        MenuStore.openSlot = newValue
                        schedulePush()
                    }
                }

                Section {
                    ForEach($items) { $item in
                        itemEditor($item)
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    Button {
                        var item = WatchMenuItem()
                        let used = Set(items.map(\.slot))
                        if let free = WatchMenuItem.slots.map(\.action).first(where: { !used.contains($0) }) {
                            item.slot = free
                        }
                        items.append(item)
                    } label: { Label("Add item", systemImage: "plus") }
                        .disabled(items.count >= 4)
                } header: {
                    Text("Items (max 4 — one slot stays free for Back)")
                } footer: {
                    Text("Changes are sent automatically. Hold/press the chosen button on the watchface to open the menu. \"Send to phone\" answers need Bluetooth connected.")
                }
            }
        }
        .navigationTitle("On-watch menu")
        .themedList()
        .onChange(of: items) { _, _ in
            MenuStore.items = items
            schedulePush()
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeWatchChanged)) { _ in
            enabled = MenuStore.isEnabled
            title = MenuStore.title
            openSlot = MenuStore.openSlot
            items = MenuStore.items
        }
    }

    private func itemEditor(_ item: Binding<WatchMenuItem>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Label", text: item.label)
                .font(.subheadline.bold())
            Picker("Button", selection: item.slot) {
                ForEach(WatchMenuItem.slots, id: \.action) { slot in
                    Text(slot.title).tag(slot.action)
                }
            }
            Picker("Action", selection: item.kind) {
                Text("Show message").tag(WatchMenuItem.Kind.showMessage)
                Text("Open watch app").tag(WatchMenuItem.Kind.openApp)
                Text("Send to phone").tag(WatchMenuItem.Kind.sendToPhone)
            }
            switch item.wrappedValue.kind {
            case .showMessage:
                TextField("Message to show", text: item.text)
            case .openApp:
                Picker("App", selection: item.text) {
                    Text("Pick…").tag("")
                    ForEach(watch.installedApps.filter { !$0.isWatchface }) { app in
                        Text(app.name).tag(app.name)
                    }
                }
            case .sendToPhone:
                Picker("Phone does", selection: item.phoneAction) {
                    Text("Reply with text").tag(WatchMenuItem.PhoneAction.reply)
                    Text("Ring the phone").tag(WatchMenuItem.PhoneAction.findPhone)
                    Text("Commute ETA").tag(WatchMenuItem.PhoneAction.commuteETA)
                }
                switch item.wrappedValue.phoneAction {
                case .reply:
                    TextField("Reply text", text: item.text)
                case .commuteETA:
                    Picker("Destination", selection: item.text) {
                        Text("Pick…").tag("")
                        ForEach(CommuteStore.items) { destination in
                            Text(destination.name).tag(destination.name)
                        }
                    }
                    if let dest = CommuteStore.item(named: item.wrappedValue.text),
                       !dest.hasCoordinates {
                        Text("This destination has no location yet — attach one in Commute destinations to get a live ETA.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                case .findPhone:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  WatchRegistry.activeKindSync().hasCustomMenu,
                  watch.connectionState == .ready, watch.isAuthenticated else { return }
            do {
                try await watch.pushMenuStructure()
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
}
