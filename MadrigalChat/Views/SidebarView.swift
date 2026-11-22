import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]

    @Binding var selection: SidebarSelection?
    @Binding var showingSettings: Bool
    let newChat: (Project?) -> Void
    let newProject: () -> Void
    /// Drops the selection without the leave checks, for deletions.
    let clearSelection: () -> Void

    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deletingProject: Project?
    @State private var searchText = ""
    @State private var searchHits: [Conversation.SearchHit] = []
    @FocusState private var searchFocused: Bool

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var loose: [Conversation] {
        conversations.filter { $0.project == nil }
    }

    /// Only loose pinned chats: a pinned chat inside a project already has a
    /// row under that project, and two rows with the same tag make the list's
    /// selection ambiguous.
    private var pinned: [Conversation] {
        conversations.filter { $0.pinned && $0.project == nil }
    }

    var body: some View {
        List(selection: $selection) {
            if query.isEmpty {
                browseSections
            } else {
                searchSection
            }
        }
        #if os(macOS)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search chats")
        #else
        // Search and New Chat live at the bottom on iOS for thumb reach.
        .bottomBar { bottomBar }
        .onChange(of: selection) { searchFocused = false }
        #endif
        // Searched once per pause in typing, not on every render.
        .task(id: query) {
            guard !query.isEmpty else {
                searchHits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            searchHits = Conversation.search(query, in: conversations, context: context)
        }
        .navigationTitle("Madrigal")
        #if os(iOS)
        // Keeps the title on the same row as the toolbar buttons instead of
        // a separate large-title row below them.
        .toolbarTitleDisplayMode(.inlineLarge)
        #endif
        .toolbar {
            ToolbarItem {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .alert("Rename chat", isPresented: $renaming.isPresent()) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                renaming?.title = renameText.isEmpty ? Conversation.defaultTitle : renameText
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete \"\(deletingProject?.name ?? "")\"?",
            isPresented: $deletingProject.isPresent(),
            titleVisibility: .visible,
            presenting: deletingProject
        ) { project in
            Button("Delete Project", role: .destructive) {
                delete(project)
            }
            Button("Cancel", role: .cancel) { deletingProject = nil }
        } message: { project in
            let count = project.conversations?.count ?? 0
            Text("Deletes the project and its \(count) \(count == 1 ? "chat" : "chats"). This can't be undone.")
        }
    }

    @ViewBuilder
    private var browseSections: some View {
        #if os(macOS)
        Section {
            Button {
                newChat(nil)
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .fullRowTappable()
            }
            .buttonStyle(.plain)
        }
        #endif

        if !pinned.isEmpty {
            Section("Pinned") {
                ForEach(pinned) { conversation in
                    row(for: conversation)
                }
            }
        }

        Section {
            ForEach(projects) { project in
                DisclosureGroup {
                    ForEach(project.sortedConversations) { conversation in
                        row(for: conversation)
                    }
                    Button {
                        newChat(project)
                    } label: {
                        Label("New chat here", systemImage: "plus")
                            .font(.callout)
                            .fullRowTappable()
                    }
                    .buttonStyle(.plain)
                } label: {
                    // The context menu lives on the label, not the
                    // DisclosureGroup: in an iOS List a menu on the group
                    // applies to every child row and replaces each chat's
                    // own menu.
                    Label(project.displayName, systemImage: project.iconSystemName)
                        .tag(SidebarSelection.project(project))
                        .contextMenu {
                            Button("Edit Project") {
                                selection = .project(project)
                            }
                            Divider()
                            Button("Delete Project", role: .destructive) {
                                deletingProject = project
                            }
                        }
                }
            }
        } header: {
            HStack {
                Text("Projects")
                Spacer()
                Button {
                    newProject()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .touchTarget()
                .accessibilityLabel("New Project")
            }
        }

        let recent = loose.filter { !$0.pinned }
        if !recent.isEmpty {
            Section("Recent") {
                ForEach(recent) { conversation in
                    row(for: conversation)
                }
            }
        }
    }

    #if os(iOS)
    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search chats", text: $searchText)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { searchFocused = false }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .capsuleSurface()

            Button {
                newChat(nil)
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .prominentCapsuleButton()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
    #endif

    private var searchSection: some View {
        Section("Results") {
            if searchHits.isEmpty {
                Text("No chats match \u{201C}\(query)\u{201D}.")
                    .foregroundStyle(.secondary)
            }
            // Skips chats deleted since the search ran.
            ForEach(searchHits.filter { $0.conversation.isLive }) { hit in
                row(for: hit.conversation, excerpt: hit.excerpt)
            }
        }
    }

    @ViewBuilder
    private func row(for conversation: Conversation, excerpt: String? = nil) -> some View {
        let subtitle = conversation.displayModelName(
            agents: agents, config: conversation.resolveConfig(among: providers)
        )
        // Selection-driven rather than NavigationLink(value:), because the
        // detail column is keyed off the List's selection binding.
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title)
                .lineLimit(1)
            if let excerpt {
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .tag(SidebarSelection.conversation(conversation))
        .swipeActions(edge: .leading) {
            Button(conversation.pinned ? "Unpin" : "Pin",
                   systemImage: conversation.pinned ? "pin.slash" : "pin") {
                conversation.pinned.toggle()
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleteConversation(conversation)
            }
        }
        .contextMenu {
            Button(conversation.pinned ? "Unpin" : "Pin") {
                conversation.pinned.toggle()
            }
            Button("Rename") {
                renameText = conversation.title
                renaming = conversation
            }
            if !projects.isEmpty {
                Menu("Move to Project") {
                    Button("None") { conversation.project = nil }
                    ForEach(projects) { project in
                        Button(project.displayName) { conversation.project = project }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                deleteConversation(conversation)
            }
        }
    }

    private func deleteConversation(_ conversation: Conversation) {
        if selection == .conversation(conversation) {
            clearSelection()
        }
        conversation.delete(from: context)
    }

    private func delete(_ project: Project) {
        switch selection {
        case .project(let selected) where selected == project:
            clearSelection()
        case .conversation(let selected) where selected.project == project:
            clearSelection()
        default:
            break
        }
        deletingProject = nil
        for conversation in project.conversations ?? [] {
            conversation.forgetDeviceModel()
        }
        context.delete(project)
    }
}

#if os(iOS)
private extension View {
    /// Pins content to the bottom edge. On iOS 26 `safeAreaBar` gives the list
    /// a scroll edge effect behind it; earlier versions fade the list out instead.
    @ViewBuilder
    func bottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom, content: content)
        } else {
            safeAreaInset(edge: .bottom) {
                content()
                    .padding(.top, 12)
                    .background {
                        LinearGradient(
                            colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                            startPoint: .top,
                            endPoint: .center
                        )
                        .ignoresSafeArea()
                    }
            }
        }
    }

    @ViewBuilder
    func capsuleSurface() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func prominentCapsuleButton() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
    }
}
#endif
