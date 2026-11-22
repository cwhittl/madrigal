import SwiftUI
import SwiftData

/// What the sidebar list has selected. A single selection type lets the
/// List drive navigation for both chats and projects — on iPhone the
/// collapsed split view only pushes the detail column when the List's own
/// selection changes.
enum SidebarSelection: Hashable {
    case conversation(Conversation)
    case project(Project)
}

struct RootSplitView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    /// The backing state. Navigation goes through `guardedSelection`; only
    /// deletions set this directly.
    @State private var selection: SidebarSelection?
    /// A project created with New Project and not yet left, so leaving it
    /// unnamed offers Discard.
    @State private var draftProjectID: PersistentIdentifier?
    /// Navigation held back because the open project has no name.
    @State private var blockedLeave: BlockedLeave?
    @State private var showingSettings = false
    /// Settings opens straight to the provider presets.
    @State private var settingsAddsProvider = false
    /// Set when Delete All Data is confirmed; the delete runs once the
    /// Settings sheet has dismissed.
    @State private var pendingDeleteAll = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Set by the open chat while it streams, so the menu bar can stop it.
    @State private var stopGenerating: (() -> Void)?
    @AppStorage(AppConfig.acceptedDataDisclosureKey) private var acceptedDisclosure = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selection: guardedSelection,
                showingSettings: $showingSettings,
                newChat: newChat(in:),
                newProject: newProject,
                clearSelection: clearSelection
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            switch selection {
            case .project(let project):
                ProjectDetailView(project: project, selection: guardedSelection) {
                    newChat(in: project)
                }
            case .conversation(let conversation):
                ChatView(conversation: conversation, stopGenerating: $stopGenerating, addProvider: addProvider)
                    .id(conversation.stableID)
            case nil:
                emptyState
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            settingsAddsProvider = false
            runPendingDeleteAll()
        }) {
            NavigationStack {
                SettingsView(onDeleteAll: requestDeleteAll, addsProviderOnAppear: settingsAddsProvider)
            }
            .macSheetSize(minWidth: 620, minHeight: 480)
        }
        // Required before anything is sent to a third-party AI service
        // (App Review Guideline 5.1.2(i)).
        .sheet(isPresented: Binding(
            get: { !acceptedDisclosure },
            set: { _ in }
        )) {
            NavigationStack {
                DataDisclosureView { acceptedDisclosure = true }
            }
            .interactiveDismissDisabled()
            #if os(macOS)
            .frame(width: 480, height: 520)
            #endif
        }
        .alert(
            blockedLeave?.isDraft == true ? "Discard new project?" : "Project needs a name",
            isPresented: $blockedLeave.isPresent(),
            presenting: blockedLeave
        ) { blocked in
            if blocked.isDraft {
                Button("Discard", role: .destructive) { discard(blocked) }
                Button("Keep Editing", role: .cancel) { }
            } else {
                Button("OK", role: .cancel) { }
            }
        } message: { blocked in
            Text(blocked.isDraft
                 ? "The project has no name. Discard it, or keep editing to give it one."
                 : "Give the project a name before leaving it.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .madrigalWillDeleteAllData)) { _ in
            clearSelection()
        }
        // A tapped reply notification opens its chat.
        .onReceive(NotificationCenter.default.publisher(for: ReplyNotifier.openConversation)) { _ in
            openPendingConversation()
        }
        .onAppear {
            // Before anything can start a reply in this launch.
            InterruptedReplies.shared.recoverOnce(in: context, notifier: .shared)
            DeviceModelPreferences.shared.pruneChatModelsOnce(in: context)
            openPendingConversation()
        }
        // Asks for notification access on first launch, once the data
        // disclosure is accepted so the system prompt doesn't cover it.
        // Does nothing once the user has decided.
        .task(id: acceptedDisclosure) {
            guard acceptedDisclosure else { return }
            #if DEBUG
            if ScreenshotDemo.isActive { return }
            #endif
            ReplyNotifier.shared.requestAuthorizationIfNeeded()
        }
        #if DEBUG
        .task {
            guard ScreenshotDemo.isActive else { return }
            // A collapsed (iPhone) split view only pushes a selection made
            // once the list is on screen.
            try? await Task.sleep(for: .milliseconds(500))
            (selection, showingSettings) = ScreenshotDemo.startState(context: context)
            #if os(macOS)
            ScreenshotDemo.sizeMainWindow()
            #endif
        }
        #endif
        .focusedSceneValue(\.sceneActions, SceneActions(
            newChat: { newChat(in: nil) },
            newProject: newProject,
            stopGenerating: stopGenerating
        ))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                Image(.madrigalMark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                Text("Madrigal")
                    .font(.title2.weight(.semibold))
            }
        } description: {
            Text(providers.isEmpty
                 ? "Connect a provider to start chatting."
                 : "Pick a conversation, or start a new one.")
        } actions: {
            if providers.isEmpty {
                Button("Add Provider", action: addProvider)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("New Chat") { newChat(in: nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Selection

    private struct BlockedLeave {
        let project: Project
        let isDraft: Bool
        /// What the user tried to do, run if they discard the project.
        let proceed: () -> Void
    }

    /// The selection the sidebar and detail views navigate with. Leaving an
    /// unnamed project is refused, and leaving an empty chat deletes it.
    private var guardedSelection: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { newValue in
                guard newValue != selection else { return }
                leaveCurrent { select(newValue) }
            }
        )
    }

    /// Runs `proceed` if the open project can be left, else holds it back
    /// behind an alert. Anything that navigates away, or creates something
    /// to navigate to, goes through here first so nothing is created only to
    /// be stranded.
    private func leaveCurrent(then proceed: @escaping () -> Void) {
        if case .project(let project)? = selection, project.isLive, !project.isValid {
            blockedLeave = BlockedLeave(
                project: project,
                isDraft: project.persistentModelID == draftProjectID,
                proceed: proceed
            )
            return
        }
        proceed()
    }

    /// Switches to `newValue` and tidies up after what was open.
    private func select(_ newValue: SidebarSelection?) {
        let previous = selection
        selection = newValue
        switch previous {
        case .project(let project)?:
            if project.persistentModelID == draftProjectID { draftProjectID = nil }
        case .conversation(let conversation)? where conversation.isLive && conversation.isDisposable:
            // Deleted here rather than in ChatView.onDisappear, which runs
            // after the replacement view is already up.
            conversation.delete(from: context)
        default:
            break
        }
    }

    private func discard(_ blocked: BlockedLeave) {
        blockedLeave = nil
        selection = nil
        draftProjectID = nil
        context.delete(blocked.project)
        blocked.proceed()
    }

    /// Tears down every view holding a model before anything is deleted:
    /// clears the selection here and in other windows, then closes Settings.
    /// The delete itself waits for the sheet's `onDismiss`, since a deleted
    /// model read by a view still on screen is a fatal error.
    private func requestDeleteAll() {
        NotificationCenter.default.post(name: .madrigalWillDeleteAllData, object: nil)
        clearSelection()
        pendingDeleteAll = true
        showingSettings = false
    }

    private func runPendingDeleteAll() {
        guard pendingDeleteAll else { return }
        pendingDeleteAll = false
        SettingsActions.deleteAllData(context: context, providers: providers)
    }

    /// For deletions: drops the selection without the leave checks.
    private func clearSelection() {
        selection = nil
        draftProjectID = nil
    }

    /// Opens a new chat, or stays on the open one if nothing was sent in it
    /// yet, so repeated New Chat doesn't pile up empty chats.
    private func newChat(in project: Project?) {
        leaveCurrent {
            // The project may have just been discarded.
            guard project?.isLive ?? true else { return }
            if case .conversation(let open)? = selection, open.isLive, open.isDisposable, open.project == project {
                return
            }
            select(.conversation(Conversation.create(in: project, providers: providers, agents: agents, context: context)))
        }
    }

    private func addProvider() {
        settingsAddsProvider = true
        showingSettings = true
    }

    private func openPendingConversation() {
        guard let id = ReplyNotifier.shared.takePendingConversationID() else { return }
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.stableID == id })
        descriptor.fetchLimit = 1
        if let conversation = try? context.fetch(descriptor).first {
            guardedSelection.wrappedValue = .conversation(conversation)
        }
    }

    private func newProject() {
        leaveCurrent {
            // Blank, so it can't be left until it's given a name.
            let project = Project(name: "")
            context.insert(project)
            // The persistent ID is only stable once saved.
            context.saveOrLog("new project")
            select(.project(project))
            draftProjectID = project.persistentModelID
        }
    }
}
