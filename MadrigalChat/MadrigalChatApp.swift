import SwiftUI
import SwiftData

enum AppConfig {
    /// Requires the iCloud capability with CloudKit and this container in
    /// the Apple Developer account. The schema must also be deployed to the
    /// Production environment before TestFlight or App Store builds can sync.
    static let enableCloudKitSync = true

    static let cloudKitContainerID = "iCloud.dev.whittle.madrigalchat"

    /// When the app is hosting unit tests, it must not touch the real store
    /// or CloudKit, which also raises an uncatchable exception in an
    /// unsigned test build.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Published from `docs/` with GitHub Pages. The same URLs go in App
    /// Store Connect.
    static let privacyPolicyURL = URL(string: "https://cwhittl.github.io/madrigal/privacy.html")!
    static let supportURL = URL(string: "https://cwhittl.github.io/madrigal/support.html")!

    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    /// UserDefaults keys. Per device, not synced.
    static let globalInstructionsKey = "globalInstructions"
    static let acceptedDataDisclosureKey = "acceptedDataDisclosure"
    static let appearanceKey = "appearance"
    /// Whether a reasoning model's thinking opens while it streams. Off by default.
    static let expandThinkingKey = "expandThinking"
}

/// The user's light/dark choice. `system` follows the OS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    /// Applies the appearance choice app-wide. On macOS this sets
    /// `NSApp.appearance`, which reaches every window including Settings
    /// and, unlike `preferredColorScheme(nil)`, reliably returns to
    /// following the system.
    func appearance(_ appearance: AppAppearance) -> some View {
        #if os(macOS)
        onAppear { NSApp.appearance = appearance.nsAppearance }
            .onChange(of: appearance) { NSApp.appearance = appearance.nsAppearance }
        #else
        preferredColorScheme(appearance.colorScheme)
        #endif
    }
}

#if os(macOS)
private extension AppAppearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
#endif

/// Opens the store, and keeps the error if it can't, so a bad store shows a
/// recovery screen instead of crashing at launch.
@Observable
@MainActor
final class StoreLoader {
    private(set) var container: ModelContainer?
    private(set) var error: Error?

    private let schema = Schema(versionedSchema: MadrigalSchemaV1.self)

    /// Screenshot demo mode gets the same in-memory store, filled with fake
    /// chats. Debug builds only.
    private static var isScreenshotDemo: Bool {
        #if DEBUG
        ScreenshotDemo.isActive
        #else
        false
        #endif
    }

    private var configuration: ModelConfiguration {
        if AppConfig.isHostingTests || Self.isScreenshotDemo {
            return ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        return ModelConfiguration(
            schema: schema,
            cloudKitDatabase: AppConfig.enableCloudKitSync
                ? .private(AppConfig.cloudKitContainerID)
                : .none
        )
    }

    init() { load() }

    func load() {
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            error = nil
            #if DEBUG
            if let container, Self.isScreenshotDemo {
                ScreenshotDemo.prepareDefaults()
                ScreenshotDemo.seed(container.mainContext)
            }
            #endif
        } catch {
            container = nil
            self.error = error
        }
    }

    /// Deletes the on-device store and opens a fresh one. With sync on,
    /// iCloud still has everything and downloads it again.
    func resetLocalStore() {
        let url = configuration.url
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
        load()
    }
}

@main
struct MadrigalChatApp: App {

    @State private var store: StoreLoader
    @AppStorage(AppConfig.appearanceKey) private var appearance: AppAppearance = .system

    init() {
        #if DEBUG
        CloudSchemaInitializer.runFromCommandLineIfRequested()
        #endif
        // Set before launch finishes so a tap that launched the app arrives.
        ReplyNotifier.shared.install()
        // Listening before the store opens, so the first setup event isn't missed.
        _ = CloudSyncMonitor.shared
        // Watching the app lifecycle before any on-device generation starts,
        // so leaving the app early still pauses it.
        _ = GenerationLifecycle.shared
        _store = State(initialValue: StoreLoader())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = store.container {
                    RootSplitView()
                        .modelContainer(container)
                        .environment(\.isOnline, NetworkMonitor.shared.isOnline)
                        .environment(\.cloudSync, CloudSyncMonitor.shared)
                } else {
                    StoreErrorView(store: store)
                }
            }
            .appearance(appearance)
        }
        .commands { AppCommands() }

        #if os(macOS)
        Settings {
            if let container = store.container {
                // A stack so the Privacy and Sync status links can push.
                NavigationStack {
                    SettingsView()
                }
                .modelContainer(container)
                .environment(\.cloudSync, CloudSyncMonitor.shared)
                .frame(minWidth: 560, minHeight: 420)
            } else {
                StoreErrorView(store: store)
            }
        }
        #endif
    }
}

// MARK: - Commands

/// What the focused window can do, published for the menu bar.
struct SceneActions {
    let newChat: () -> Void
    let newProject: () -> Void
    let stopGenerating: (() -> Void)?
}

private struct SceneActionsKey: FocusedValueKey {
    typealias Value = SceneActions
}

extension FocusedValues {
    var sceneActions: SceneActions? {
        get { self[SceneActionsKey.self] }
        set { self[SceneActionsKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.sceneActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { actions?.newChat() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
            Button("New Project") { actions?.newProject() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Stop Generating") { actions?.stopGenerating?() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(actions?.stopGenerating == nil)
        }
    }
}

// MARK: - Store failure

struct StoreErrorView: View {
    let store: StoreLoader
    @State private var confirmingReset = false

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't open your chats", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            VStack(spacing: 8) {
                Text("Madrigal couldn't open its database on this device.")
                if let error = store.error {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } actions: {
            Button("Try Again") { store.load() }
                .buttonStyle(.borderedProminent)
            Button("Reset Local Data", role: .destructive) { confirmingReset = true }
        }
        .frame(minWidth: 360, minHeight: 300)
        .confirmationDialog("Reset local data?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Local Data", role: .destructive) { store.resetLocalStore() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(AppConfig.enableCloudKitSync
                 ? "Deletes the copy of your chats stored on this device. Chats already synced to iCloud download again afterwards."
                 : "Deletes every chat and project stored on this device. This can't be undone.")
        }
    }
}
