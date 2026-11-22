#if DEBUG
import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

/// Fake chats for App Store screenshots. Debug builds only, and only with
/// the `-ScreenshotDemo YES` launch arguments. (The value matters on macOS:
/// AppKit reads arguments as `-key value` pairs and would treat a stray
/// word as a file to open, and then opens no window.) The store is then in memory with
/// no CloudKit (see `StoreLoader`), so real chats and iCloud are never
/// touched, and nothing is written to the Keychain or to UserDefaults.
///
/// `-DemoScreen <chat|sidebar|project|search|settings|newchat>` picks what
/// the window opens on. `AppStore/capture-screenshots.sh` drives it.
@MainActor
enum ScreenshotDemo {
    nonisolated static let isActive = ProcessInfo.processInfo.arguments.contains("-ScreenshotDemo")

    enum Screen: String {
        /// A hosted chat with a rich Markdown reply.
        case chat
        /// The sidebar, with pinned chats and projects.
        case sidebar
        /// A project's instructions and knowledge files.
        case project
        /// An on-device chat that searched the web.
        case search
        /// Settings, with providers and agents.
        case settings
        /// A fresh chat with an agent.
        case newchat
    }

    static var screen: Screen {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DemoScreen"), index + 1 < arguments.count else { return .chat }
        return Screen(rawValue: arguments[index + 1]) ?? .chat
    }

    /// Volatile overrides: the disclosure sheet stays away, appearance
    /// follows the system or `-DemoAppearance`, and Settings shows
    /// demo instructions instead of this device's own.
    static func prepareDefaults() {
        guard isActive else { return }
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[AppConfig.acceptedDataDisclosureKey] = true
        // `-DemoAppearance light|dark` pins it (the Mac capture can't flip
        // the system appearance per shot); otherwise follow the system.
        let launch = ProcessInfo.processInfo.arguments
        let pinned = launch.firstIndex(of: "-DemoAppearance").flatMap { $0 + 1 < launch.count ? AppAppearance(rawValue: launch[$0 + 1]) : nil }
        arguments[AppConfig.appearanceKey] = (pinned ?? .system).rawValue
        arguments[AppConfig.globalInstructionsKey] = "Keep answers short unless I ask for detail. Use metric units, and show code in Swift when it applies."
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    // MARK: - Opening screen

    /// What `RootSplitView` should show first: the selection, and whether
    /// Settings is open.
    static func startState(context: ModelContext) -> (selection: SidebarSelection?, showingSettings: Bool) {
        func conversation(_ title: String) -> SidebarSelection? {
            var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == title })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor).first).map { .conversation($0) }
        }
        func project(_ name: String) -> SidebarSelection? {
            var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.name == name })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor).first).map { .project($0) }
        }

        switch screen {
        case .chat: return (conversation(Titles.featured), false)
        case .search: return (conversation(Titles.search), false)
        case .project: return (project(Titles.kitchen), false)
        case .settings:
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone { return (nil, true) }
            #endif
            return (conversation(Titles.lisbon), true)
        case .newchat: return (conversation(Titles.newChat), false)
        case .sidebar:
            // On iPhone the sidebar is the whole screen; on iPad and Mac a
            // chat fills the detail column next to it.
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone { return (nil, false) }
            #endif
            return (conversation(Titles.lisbon), false)
        }
    }

    #if os(macOS)
    /// Sizes the main window to 1280×800 points (2560×1600 pixels on
    /// Retina), centers it, and prints its window number and frame for the
    /// capture script.
    static func sizeMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let screen = window.screen ?? NSScreen.main else {
                print("DEMO_WINDOW none: \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible)" })")
                fflush(stdout)
                return
            }
            let size = NSSize(width: 1280, height: 800)
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // screencapture -R wants top-left coordinates.
            let frame = window.frame
            let top = screen.frame.maxY - frame.maxY
            print("DEMO_WINDOW id=\(window.windowNumber) rect=\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))")
            fflush(stdout)
        }
    }
    #endif

    // MARK: - Seed data

    enum Titles {
        static let featured = "SwiftUI list performance"
        static let search = "Hiking Sintra in November"
        static let lisbon = "Lisbon itinerary, 4 days"
        static let newChat = "New Chat"
        static let kitchen = "Kitchen Remodel"
    }

    static func seed(_ context: ModelContext) {
        guard isActive else { return }
        let now = Date.now
        func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        // Providers
        let openRouter = provider("openrouter", context: context, created: ago(minutes: 90_000))
        openRouter.isDefault = true
        openRouter.cachedModelIDs = ["openai/gpt-5", "google/gemini-2.5-pro", "deepseek/deepseek-r1", "meta-llama/llama-4-maverick"]
        openRouter.preferredModelID = "openai/gpt-5"

        let apple = provider("apple", context: context, created: ago(minutes: 80_000))

        let mlx = provider("mlx", context: context, created: ago(minutes: 70_000))
        mlx.cachedModelIDs = ["mlx-community/Qwen3-4B-4bit", "mlx-community/gemma-3-4b-it-4bit"]
        mlx.preferredModelID = "mlx-community/Qwen3-4B-4bit"
        mlx.webSearchMode = .always
        mlx.webSearchBackend = .onDevice

        // Agents
        let reviewer = Agent(name: "Code Reviewer")
        reviewer.iconSystemName = "chevron.left.forwardslash.chevron.right"
        reviewer.colorHex = "#7C5CE0"
        reviewer.instructions = "Review Swift code like a senior iOS engineer. Point out correctness issues first, then performance, then style. Show fixes as code."
        reviewer.providerKeychainKey = openRouter.keychainKey
        reviewer.modelID = "openai/gpt-5"
        reviewer.createdAt = ago(minutes: 60_000)
        context.insert(reviewer)

        let travel = Agent(name: "Travel Planner")
        travel.iconSystemName = "airplane"
        travel.colorHex = "#E0815C"
        travel.instructions = "Plan trips day by day. Group sights by neighborhood, note opening hours, and suggest one local place to eat for each day."
        travel.providerKeychainKey = openRouter.keychainKey
        travel.modelID = "google/gemini-2.5-pro"
        travel.createdAt = ago(minutes: 50_000)
        context.insert(travel)

        // Projects
        let kitchen = Project(name: Titles.kitchen)
        kitchen.iconSystemName = "hammer"
        kitchen.colorHex = "#E0A85C"
        kitchen.customInstructions = """
        We're remodeling a 1960s galley kitchen, 3 × 2.4 m, with a budget of $28,000. \
        Keep the plumbing where it is. Compare options in tables with rough costs, and \
        flag anything that needs a permit.
        """
        kitchen.createdAt = ago(minutes: 40_000)
        context.insert(kitchen)
        addFile("Contractor quote - Oct 2026.pdf", text: Knowledge.quote, to: kitchen, context: context, at: ago(minutes: 39_000))
        addFile("Floor plan notes.md", text: Knowledge.floorPlan, to: kitchen, context: context, at: ago(minutes: 38_000))
        addFile("Appliance shortlist.csv", text: Knowledge.appliances, to: kitchen, context: context, at: ago(minutes: 37_000))

        let ios = Project(name: "iOS Side Project")
        ios.iconSystemName = "swift"
        ios.colorHex = "#E05C5C"
        ios.customInstructions = "A habit tracker in Swift 6 and SwiftUI, iOS 17 and up. Prefer Observation and SwiftData; no third-party dependencies."
        ios.defaultAgentID = reviewer.idString
        ios.createdAt = ago(minutes: 30_000)
        context.insert(ios)
        addFile("Architecture.md", text: Knowledge.architecture, to: ios, context: context, at: ago(minutes: 29_000))

        // Chats, newest first.
        chat(Titles.featured, in: ios, agent: reviewer, providers: [openRouter], at: ago(minutes: 12), context: context, turns: [
            .user("My habit list stutters when I scroll past a few hundred rows. Each row shows a streak count. What should I look at?"),
            .assistant(Replies.listPerformance, reasoning: Replies.listThinking)
        ])
        chat(Titles.lisbon, agent: travel, providers: [openRouter], at: ago(minutes: 55), pinned: true, context: context, turns: [
            .user("Plan four days in Lisbon in early December. We like food markets, viewpoints and walking, not museums all day."),
            .assistant(Replies.lisbon)
        ])
        chat(Titles.search, provider: mlx, model: "mlx-community/Qwen3-4B-4bit", at: ago(minutes: 140), context: context, turns: [
            .user("Is it worth hiking from Sintra to Pena Palace in November? How long does it take?"),
            .assistant(Replies.sintra, searches: Replies.sintraSearches)
        ])
        chat("Countertops: quartz vs. granite", in: kitchen, provider: openRouter, model: "openai/gpt-5", at: ago(minutes: 300), context: context, turns: [
            .user("Quartz or granite for about 4 m² of counter, given the quote?"),
            .assistant(Replies.countertops)
        ])
        chat("What does this lease clause mean?", provider: openRouter, model: "google/gemini-2.5-pro", at: ago(minutes: 1_500), context: context, turns: [
            .user("“Tenant shall be responsible for all repairs under $150 not caused by Landlord's negligence.” Does that include the dishwasher?"),
            .assistant(Replies.lease)
        ])
        chat("Weekend sourdough schedule", provider: apple, model: AppleIntelligence.modelID, at: ago(minutes: 2_900), pinned: true, context: context, turns: [
            .user("I want fresh sourdough for Sunday lunch. My starter peaks about 6 hours after feeding. Work backwards for me."),
            .assistant(Replies.sourdough)
        ])
        chat("async let vs. TaskGroup", in: ios, agent: reviewer, providers: [openRouter], at: ago(minutes: 4_400), context: context, turns: [
            .user("When should I use async let instead of a task group?"),
            .assistant("Use **`async let`** when you know the number of child tasks at compile time, like loading a profile and its avatar together. Use a **task group** when the count depends on data, such as fetching every habit's history. Both are structured, so cancellation and errors propagate the same way.")
        ])
        chat("Cabinet layout for a galley kitchen", in: kitchen, provider: openRouter, model: "openai/gpt-5", at: ago(minutes: 5_800), context: context, turns: [
            .user("What's the best work-triangle layout for a 3 m galley?"),
            .assistant("Put the sink on the window wall and the range opposite, offset by about 60 cm so two people don't collide. Keep the fridge at the end nearest the dining room.")
        ])
        chat("Birthday toast for my sister", provider: apple, model: AppleIntelligence.modelID, at: ago(minutes: 8_700), context: context, turns: [
            .user("Write a short, funny birthday toast for my sister Maya, who just ran her first marathon."),
            .assistant("To Maya, who spent months training to run 42 kilometers, and still takes the elevator to the second floor. Here's to the next mile, and to the cake waiting at the finish. Cheers!")
        ])

        if screen == .newchat {
            let fresh = Conversation.create(in: nil, providers: [openRouter], agents: [reviewer, travel], context: context)
            fresh.apply(travel, providers: [openRouter])
            fresh.updatedAt = now
        }

        context.saveOrLog("screenshot demo")
    }

    // MARK: - Builders

    private enum Turn {
        case user(String)
        case assistant(String, reasoning: String = "", searches: [WebSearchRecord] = [])
    }

    private static func provider(_ presetID: String, context: ModelContext, created: Date) -> ProviderConfig {
        let config = ProviderConfig()
        ProviderPreset.all.first { $0.id == presetID }!.apply(to: config)
        config.createdAt = created
        context.insert(config)
        return config
    }

    private static func addFile(_ name: String, text: String, to project: Project, context: ModelContext, at date: Date) {
        let file = ProjectFile(filename: name, extractedText: text)
        file.addedAt = date
        context.insert(file)
        file.project = project
    }

    private static func chat(
        _ title: String,
        in project: Project? = nil,
        agent: Agent? = nil,
        provider: ProviderConfig? = nil,
        model: String = "",
        providers: [ProviderConfig] = [],
        at date: Date,
        pinned: Bool = false,
        context: ModelContext,
        turns: [Turn]
    ) {
        let conversation = Conversation(title: title)
        conversation.pinned = pinned
        if let agent {
            conversation.apply(agent, providers: providers)
        } else if let provider {
            conversation.providerLabel = provider.name
            conversation.providerKeychainKey = provider.keychainKey
            conversation.modelID = model
        }
        context.insert(conversation)
        conversation.project = project

        var time = date.addingTimeInterval(-Double(turns.count) * 45)
        for turn in turns {
            let message: Message
            switch turn {
            case .user(let text):
                message = Message(role: .user, content: text)
            case .assistant(let text, let reasoning, let searches):
                message = Message(role: .assistant, content: text)
                message.reasoning = reasoning
                message.modelID = conversation.modelID
                message.toolPayloadJSON = ToolPayload(webSearch: searches).json
            }
            message.createdAt = time
            time = time.addingTimeInterval(45)
            context.insert(message)
            message.conversation = conversation
        }
        conversation.createdAt = date.addingTimeInterval(-Double(turns.count) * 45)
        conversation.updatedAt = date
        project?.updatedAt = max(project?.updatedAt ?? .distantPast, date)
    }

    // MARK: - Content

    private enum Replies {
        static let listThinking = """
        A few hundred rows shouldn't stutter in a List, so something is doing work per row on the main thread. \
        "Streak count" suggests each row computes a streak from its completion history. If that's a computed \
        property walking a relationship, every row that appears runs it. Also check for ForEach with \
        unstable ids and for a whole-model observation that invalidates every row.
        """

        static let listPerformance = """
        ## Likely cause: the streak is computed on every render

        A few hundred rows is small for `List`, so the stutter is almost always **work done per row on the main thread**. The usual suspects:

        - **A computed `streak`** that walks every completion each time the row's body runs
        - **Unstable identity**, such as `ForEach(habits.indices, id: \\.self)`, so rows are rebuilt instead of reused
        - **Date formatting** with a new `DateFormatter` per row

        ### Fix: store the streak, update it on write

        ```swift
        @Model final class Habit {
            var name = ""
            var streak = 0   // cached
            var done: [Completion] = []

            func complete(on day: Date) {
                done.append(Completion(day))
                streak = Streak.count(done)
            }
        }
        ```

        Then each row only reads a stored property:

        ```swift
        List(habits) { habit in
            HabitRow(habit.name,
                     streak: habit.streak)
        }
        ```

        ### What to expect

        | Change | Main-thread time per scroll | Effort |
        |---|---|---|
        | Cache `streak` | −80% | Small |
        | Stable `id` | −10% | Trivial |
        | Shared formatter | −5% | Trivial |

        Profile with the **SwiftUI** instrument before and after; the "Long View Body Updates" lane should go quiet.
        """

        static let lisbon = """
        ## Four days in Lisbon

        **Day 1 · Baixa and Alfama.** Start at Praça do Comércio, walk up to the Sé, and catch sunset at **Miradouro de Santa Luzia**. Dinner: grilled fish at a tasca in Alfama.

        **Day 2 · Belém.** Jerónimos Monastery opens at 9:30; get there early, then pastéis de Belém still warm. Walk the river to the MAAT.

        **Day 3 · Sintra day trip.** Train from Rossio, 40 minutes. Pena Palace first, Quinta da Regaleira after lunch.

        **Day 4 · Markets and viewpoints.** **Time Out Market** for lunch, then the 28 tram and **Miradouro da Senhora do Monte** for the best view in the city.

        | Day | Walking | Must-book |
        |---|---|---|
        | 1 | 7 km | — |
        | 2 | 9 km | Jerónimos tickets |
        | 3 | 12 km | Pena Palace timed entry |
        | 4 | 6 km | — |
        """

        static let sintra = """
        Yes, November is a good month for it: cooler and much quieter than summer, though trails can be muddy after rain [2].

        - **Route:** from Sintra's historic center, the **Vila Sassetti trail** climbs to Pena Palace through the forest [1].
        - **Time:** about 45–60 minutes up, roughly 2 km with 300 m of climbing [1][3].
        - **Tickets:** Pena uses timed entry; book the park and palace online ahead of time [2].
        - **Tip:** wear shoes with grip, and leave time for the Moorish Castle next door.
        """

        static let sintraSearches: [WebSearchRecord] = [
            WebSearchRecord(query: "Sintra to Pena Palace hike November", results: [
                SearchResult(title: "Vila Sassetti trail to Pena Palace", url: "https://www.parquesdesintra.pt/en/parks-monuments/villa-sassetti/", snippet: "A walking route from the historic center to the Pena Park."),
                SearchResult(title: "Pena Palace: opening hours and tickets", url: "https://www.parquesdesintra.pt/en/parks-monuments/park-and-national-palace-of-pena/", snippet: "Timed entry. Open daily except 25 December and 1 January."),
                SearchResult(title: "Sintra hiking guide", url: "https://www.visitportugal.com/en/content/sintra", snippet: "Trails through the Sintra hills, best in spring and autumn."),
                SearchResult(title: "Sintra – Wikipedia", url: "https://en.wikipedia.org/wiki/Sintra", snippet: "Sintra is a town in the Lisbon metropolitan area.")
            ])
        ]

        static let countertops = """
        Based on the quote's $2,400 allowance:

        | | Quartz | Granite |
        |---|---|---|
        | Installed, 4 m² | $2,200–3,000 | $1,800–2,800 |
        | Sealing | Never | Yearly |
        | Heat | Use trivets | Handles hot pans |

        **Quartz** fits the allowance and needs no upkeep. Pick granite only if you want a natural stone look.
        """

        static let lease = """
        Probably yes, for small repairs. The clause makes you pay for any repair **under $150** unless the landlord caused the problem. So:

        - A $90 door seal on the dishwasher: **you**.
        - A $400 pump replacement: **the landlord**, since it's over the limit.
        - Damage from a landlord's botched install: **the landlord**, at any cost.

        Check whether your state limits what a landlord can shift to tenants for appliances they supplied.
        """

        static let sourdough = """
        Working back from **12:30 Sunday**:

        1. **Sat 08:00** · Feed the starter.
        2. **Sat 14:00** · Mix the dough (starter at peak).
        3. **Sat 14:30–17:30** · Four sets of stretch and folds, 45 minutes apart.
        4. **Sat 21:00** · Shape, then into the fridge overnight.
        5. **Sun 10:00** · Preheat the Dutch oven to 250 °C.
        6. **Sun 11:00** · Bake 20 min lid on, 25 min lid off.
        7. **Sun 12:00** · Cool for at least 30 minutes before slicing.
        """
    }

    private enum Knowledge {
        static let quote = """
        Northside Renovations, quote #2026-114. Demolition and disposal $1,900. Electrical: 4 new circuits, \
        under-cabinet lighting $3,600. Cabinets, shaker style, painted $9,800. Countertops allowance $2,400. \
        Backsplash tile, 3 m² $950. Flooring, LVP 7 m² $1,100. Permits $650. Contingency 10%.
        """
        static let floorPlan = """
        # Floor plan
        - Galley, 3.0 × 2.4 m; window on the north wall over the sink.
        - Door to dining room on the east end; fridge goes there.
        - Range on the south wall; gas line stays.
        """
        static let appliances = """
        type,model,price
        range,Bosch 800 series,2199
        dishwasher,Miele G 5008,1299
        fridge,LG counter-depth,1899
        """
        static let architecture = """
        # Architecture
        SwiftData models: Habit, Completion. Views read models directly; no view models. \
        Widgets read a shared App Group store. Notifications are scheduled by a single ReminderScheduler.
        """
    }
}
#endif
