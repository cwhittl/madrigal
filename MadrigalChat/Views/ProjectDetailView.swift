import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    @Bindable var project: Project
    @Binding var selection: SidebarSelection?
    /// Goes through RootSplitView, which won't strand a new chat behind an
    /// unnamed project.
    let newChat: () -> Void

    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $project.name, prompt: Text("Project name"))
                IconPicker(selection: $project.iconSystemName)
            } header: {
                Text("Project")
            } footer: {
                ValidationIssuesView(issues: project.validationIssues)
            }

            Section {
                TextEditor(text: $project.customInstructions)
                    .frame(minHeight: 120)
                    .font(.body)
            } header: {
                Text("Custom instructions")
            } footer: {
                Text("Sent with every message in this project's chats, after your instructions from Settings.")
            }

            if !agents.isEmpty {
                Section {
                    // Only bind a tag the Picker has, so a deleted agent
                    // reads as None instead of a blank selection.
                    Picker("Default agent", selection: Binding(
                        get: { Agent.find(project.defaultAgentID, in: agents) == nil ? "" : project.defaultAgentID },
                        set: { project.defaultAgentID = $0 }
                    )) {
                        Text("None").tag("")
                        ForEach(agents) { agent in
                            Text(agent.name).tag(agent.idString)
                        }
                    }
                } footer: {
                    Text("New chats in this project start with this agent.")
                }
            }

            Section {
                ForEach(project.files) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename)
                        Text("\(file.characterCount) characters")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // Form isn't List-backed on macOS, so swipeActions alone
                    // would leave no way to remove a file there.
                    .swipeActions {
                        Button("Remove", role: .destructive) { context.delete(file) }
                    }
                    .contextMenu {
                        Button("Remove", role: .destructive) { context.delete(file) }
                    }
                }
                Button {
                    importing = true
                } label: {
                    Label("Add file", systemImage: "plus")
                }
            } header: {
                Text("Knowledge files")
            } footer: {
                Text("Text from these files is injected into context, capped at \(ContextAssembler.knowledgeCharacterCap) characters in total.")
            }

            Section {
                Toggle("Share chat summaries across chats", isOn: $project.shareChatSummaries)
            } header: {
                Text("Chat memory")
            } footer: {
                Text("When you leave a chat, and every few messages, a short summary of it is saved. Other chats in this project receive these summaries, capped at \(ContextAssembler.otherChatsCharacterCap) characters. Writing a summary is an extra request to the chat's provider; pick a cheaper summary model in the provider's settings.")
            }

            Section("Conversations") {
                if project.sortedConversations.isEmpty {
                    Text("No chats in this project yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(project.sortedConversations) { conversation in
                    Button {
                        selection = .conversation(conversation)
                    } label: {
                        HStack {
                            Text(conversation.title).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .fullRowTappable()
                    }
                    .buttonStyle(.plain)
                }
                Button(action: newChat) {
                    Label("New chat in this project", systemImage: "square.and.pencil")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name.isBlank ? "Project" : project.name)
        .onChange(of: project.name) { _, _ in project.touch() }
        .onChange(of: project.customInstructions) { _, _ in project.touch() }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: FileTextExtractor.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await importFiles(urls) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Couldn't add file", isPresented: $importError.isPresent()) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    /// Extraction runs off the main actor, since a large PDF can take
    /// seconds; only the inserts happen here.
    private func importFiles(_ urls: [URL]) async {
        var failures: [String] = []
        defer {
            if !failures.isEmpty { importError = failures.joined(separator: "\n") }
        }
        for url in urls {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try FileTextExtractor.extractText(from: url)
                }.value
                // The project may have been deleted while this file was read.
                guard project.isLive else { return }
                let file = ProjectFile(filename: url.lastPathComponent, extractedText: text)
                // Insert first, then relate (see ChatViewModel.send).
                context.insert(file)
                file.project = project
            } catch {
                // Every failure is listed, not just the last one.
                failures.append(urls.count > 1
                    ? "\(url.lastPathComponent): \(error.localizedDescription)"
                    : error.localizedDescription)
            }
        }
        if project.isLive { project.touch() }
    }
}
