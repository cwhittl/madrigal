# Madrigal

A native SwiftUI multiplatform chat client (iOS 17+, iPadOS 17+, macOS 14+) for
OpenAI-compatible endpoints, Cloudflare Workers AI, Apple Intelligence, and
open-weight models run on the device itself. No backend, no accounts beyond your
own API keys. The only third-party dependencies are the Swift packages for
on-device models (MLX and the Hugging Face libraries); everything else is the SDK.

## Why "Madrigal"?

A madrigal is a Renaissance form of secular vocal music — multiple independent voices
woven together into something harmonious. Each voice carries its own line, but together
they create a richer texture than any single voice could alone.

That's a decent metaphor for what this app does. You bring the API keys (the raw voices).
The app weaves your conversations — your prompts, the model's responses, your project
context — into a clean, unified interface. Multiple conversations run side by side like
polyphonic parts. Projects with custom instructions and knowledge files act like the
score: the shared context that shapes how all the voices sound. Streaming responses
feel like a voice singing in real time, word by word.

It's elegant, it's structured, and it doesn't try to be anything other than what it is:
a clean instrument for musical conversation between you and the models you choose.

This file is what you need to open the project and get a response on screen.
Help for users is at <https://cwhittl.github.io/madrigal/support.html>.

## Open it

```
open MadrigalChat.xcodeproj
```

Xcode 16 or newer, with the Metal Toolchain installed for MLX's shaders
(`xcodebuild -downloadComponent MetalToolchain`, about 700 MB, once per Xcode).
Swift packages resolve on first open. The project uses filesystem-synchronized groups, so every
`.swift` file under `MadrigalChat/` (or `MadrigalChatTests/`) is part of its
target automatically. Adding a file means creating it on disk, nothing else.

Set your team under **Signing & Capabilities** before running on a device.
Simulator and "Sign to Run Locally" work without one.

## First run

1. Build and run.
2. Open Settings (gear in the sidebar, or Cmd-comma on macOS).
3. **Add Provider**, pick a preset, paste your key, tap **Fetch models**.
4. Pick a model, close Settings, start a chat.

### Cloudflare Workers AI

Pick the Cloudflare Workers AI preset. It asks for two things:

- **Account ID**: 32 hex characters, in the Cloudflare dashboard sidebar or in
  the URL of your account overview page. The app builds
  `https://api.cloudflare.com/client/v4/accounts/<id>/ai/v1` from it, so there
  is no base URL to type.
- **API Token**: create one at Cloudflare → My Profile → API Tokens with the
  **Workers AI: Read** permission. This is not your Global API Key, and not an
  OpenAI key.

**Fetch models** hits Cloudflare's `/ai/models/search` rather than an
OpenAI-shaped `/v1/models`, filters to text-generation models, and falls back to
a short list of known `@cf/...` IDs if the call fails. You can always type a
model ID by hand.

Chat itself is the plain OpenAI wire format, so streaming, stop, and retry
behave identically to the other providers.

Want your Workers AI traffic to go through an AI Gateway? Add a second provider
of kind "OpenAI-compatible" pointed at the gateway URL. That path already works;
gateway configuration is not built into the app.

### Local models (MLX)

Pick **On-device models (MLX)** to download open-weight models from Hugging Face
and run them in the app with [MLX Swift](https://github.com/ml-explore/mlx-swift-lm).
No network after the download, no key, unless you turn on web search.

- **Download**: the provider screen lists a catalog of `mlx-community` 4-bit
  models (Llama 3.2, Gemma 3, Qwen3, up to 8B). You can also add any repo by ID,
  for example `mlx-community/Qwen3-4B-4bit`; the app reads its size from the Hub
  first. Files go to `Application Support/Models/`, excluded from backup.
- **Fit**: each model is rated against this device's RAM as *Recommended*, *May
  be slow or unstable*, or *Needs ~N GB RAM*. These are warnings, not limits.
  Downloading a model rated too large asks for confirmation first, since the
  system may close the app while it runs.
- **Per device**: downloads never sync. The provider and your chats do, so a chat
  can name a model that isn't on this device; sending then explains that it
  needs downloading. The provider's model list follows this device's downloads.
- **Runtime**: one model stays loaded between messages. It's dropped when you
  switch models, delete it, or iOS sends a memory warning. On iOS 26, leaving the
  app moves a reply to the CPU (slower) until you come back, or keeps it on the
  GPU on iPads that allow background GPU work. Before iOS 26 it stops with a
  message saying so (and a "cut off" notification); see
  [Background replies](#background-replies).
- **Reasoning** models' `<think>` blocks show as thinking, like hosted ones.
- **Context**: the preset starts at 16,000 characters (about 4,000 tokens).
- **Hardware**: Apple silicon only. The Simulator and Intel Macs show the
  provider as unsupported. iOS builds use `MadrigalChat-iOS.entitlements`, which
  adds the Increased Memory Limit and Extended Virtual Addressing capabilities;
  the App ID needs both enabled.

### Web search for on-device models

Apple Intelligence and MLX providers can search the web. Turn it on in the
provider's **Web search** section: *Always search* searches every message
before the reply and works with any model; *Model decides* offers the model a
`web_search` tool, which small on-device models often don't call. A reply's
sources show any search that failed or found nothing, with the reason, and in
*Always search* the model is told too, so it can say so instead of guessing.

Snippets alone rarely hold the answer, so after a search the device opens the
top results' pages (one for Apple Intelligence, three for MLX), keeps the parts
that best match the query, and gives those to the model with the results.
Pages built with JavaScript give little. Weather questions ("weather in
Seattle tomorrow", "Paris forecast") also get a 7-day forecast from
[Open-Meteo](https://open-meteo.com), free and without a key, and then no
pages are read.

**Search with** picks where queries go:

- *On device* (the default) needs no server. The device queries DuckDuckGo's
  Instant Answer API, DuckDuckGo's HTML results page, and Wikipedia's search
  API at the same time, then merges the results. DuckDuckGo's HTML results are
  unofficial: the markup can change, and DuckDuckGo may rate-limit them with a
  bot check. The other sources still answer, but they rarely have general web
  results, so when they find nothing the bot check is reported as the failure.
- *Brave Search API* uses Brave's official web search API with your own key
  (from <https://api-dashboard.search.brave.com>), stored in the Keychain
  under `<provider key>.brave`. The most reliable choice on iPhone, where
  there's no server to run.
- *SearXNG server* sends queries to a SearXNG instance you run. It must allow
  JSON results:

  ```yaml
  search:
    formats: [html, json]
  ```

  Check it with `curl '<url>/search?q=test&format=json'`.

Whoever receives a query sees it and the device's IP address; replies are still
generated on the device. Results are trimmed to fit (about 1,500 characters for
Apple's small window, 4,000 for MLX), and the reply lists its sources under the
text.

## Where things are

```
MadrigalChat/
  MadrigalChatApp.swift       @main, AppConfig, store loading, menu commands
  Models/                    SwiftData @Model classes and the versioned schema
  Networking/                ChatProvider protocol, SSE parsing, the providers, presets
  Services/                  Keychain, context assembly, summaries, export, file text extraction,
                             on-device model downloads and runtime
  ViewModels/                ChatViewModel, provider editing
  Views/                     Split view, sidebar, chat, markdown, project detail, settings
MadrigalChatTests/           Unit tests (Swift Testing)
```

## Tests

```
xcodebuild test -scheme MadrigalChat -destination 'platform=macOS'
```

The tests cover the pure parts: SSE parsing, inline thinking, the markdown block
parser, context assembly, export, and search. When the app hosts tests it opens
an in-memory store without CloudKit, so they never touch real data.

`CloudflareWorkersAIProvider` subclasses `OpenAICompatibleProvider` and overrides
only three things: URL construction, model discovery, and the request body. If
you add another provider that speaks a genuinely different wire format, conform
to `ChatProvider` directly instead.

## iCloud sync

On (`AppConfig.enableCloudKitSync = true`), using the private database of
`iCloud.dev.whittle.madrigalchat`. The target has the iCloud (CloudKit),
Push Notifications, and Background Modes → Remote notifications capabilities.

The CloudKit schema has to be **deployed to Production** in the CloudKit Console
before any TestFlight or App Store build can sync; those builds never see the
Development environment.

Every model property has a default value and every relationship is optional,
which is what SwiftData's CloudKit integration requires. The models are wrapped in
`MadrigalSchemaV1`. Once v1 ships, schema changes must be additive: add properties
with defaults, never rename or remove one.

Secrets never go into CloudKit. API keys and Cloudflare Access client secrets live
in the Keychain, written with `kSecAttrSynchronizable` so they ride iCloud Keychain
to your other devices. On a locally-signed build that entitlement isn't available,
so `KeychainService` falls back to a device-local item rather than erroring out.

If the store can't be opened at launch, the app shows a recovery screen (try
again, or reset the local copy and re-download from iCloud) instead of crashing.

## Status

| Phase | State |
|---|---|
| 1 — Core chat loop | Built |
| 2 — Multi-conversation + sidebar | Built |
| 3 — Projects | Built |
| 4 — CloudKit sync | Built, on |
| 5 — Polish | Markdown (blocks and inline), copy/export, regenerate/edit, search, menu commands, stop, retry, offline detection, empty states built |
| 6 — Attachments | Project knowledge files built; image attachments not built |

Not built, on purpose: general tool-call execution, image generation. On-device
inference is built (Apple Intelligence and MLX, see above). The one tool is web
search for the on-device providers, from the device (DuckDuckGo and Wikipedia),
Brave's Search API, or a self-hosted SearXNG server, off by default. `Attachment` exists in the schema so message-level
attachments can be added later without a migration.

## Branding

The app icon and the in-app mark are generated from `madrigal-app-icon.svg`, which
is the source of truth. To change the look, edit the SVG and re-render:

```
python3 -m pip install cairosvg
python3 Scripts/render-icons.py
```

That writes `AppIcon.appiconset` (an opaque square for iOS, the rounded tile at
each macOS size) and `MadrigalMark.imageset` (the bubble alone on transparency, dots
recolored so they read against a light background). `AccentColor` is set to the
mark's violet, so tinted controls and user message bubbles match.

## Background replies

On iOS 26 and later, a hosted reply keeps streaming after you leave the app or
lock the screen. It runs as a `BGContinuedProcessingTask`, so the system shows
"Madrigal is replying" with progress and a cancel button. On iOS 17–25, or when
the system won't start one, the reply gets the classic ~30 seconds
(`beginBackgroundTask`) and is then stopped.

On-device MLX replies use Metal. Where `BGTaskScheduler.supportedResources`
includes `.gpu` (M3 and later iPads), their task asks for background GPU access
(`requiredResources = .gpu`) and the reply just keeps going. iPhones never get
background GPU access, so there the task runs without it. When the app goes to
the background, `GenerationLifecycle` cancels the GPU run and waits (up to 2 s,
inside the notification) for its GPU work to end, since a backgrounded app that
submits GPU work gets it killed. The reply then continues on the CPU from the
text so far: the chat template plus the partial reply, with no end of turn in
between. That's roughly 4–5× slower. It moves back to the GPU the same way when
the app returns. Without a continued-processing task (before iOS 26, or if the
system won't start one), an MLX reply stops as soon as the app goes to the
background and is marked cut off.

If a reply finishes, fails, or is cut off while the app isn't in front,
`ReplyNotifier` posts a local notification titled with the chat's name. Tapping
it opens that chat; a cut-off reply can be picked up again with Regenerate.
Permission is asked the first time you send a message. Continued processing
needs `BGTaskSchedulerPermittedIdentifiers` (`dev.whittle.madrigalchat.reply.*`)
in Info.plist. Background GPU access also needs the
`com.apple.developer.background-tasks.continued-processing.gpu` entitlement.

## Concurrency

Swift 6 language mode with complete checking, plus Approachable Concurrency.
UI-facing types (`ChatViewModel`, `ProviderEditViewModel`, `NetworkMonitor`,
`ScreenAwakeService`, `BackgroundActivity`, `ReplyNotifier`, `StoreLoader`, `LocalModelStore`) are
`@MainActor`, and so is
all SwiftData model access. Providers are `Sendable` and stream off the main actor.
`StreamAccumulator` collects tokens and splits out `<think>` blocks there too, then
hands the main actor a cumulative snapshot at most every 33 ms, so per-token work
never touches the UI thread. `LocalModelRuntime` is an actor that owns the one
loaded MLX model.
The one `@unchecked Sendable` is `OpenAICompatibleProvider`, because a non-final
class can't be checked; its stored properties must stay immutable.

## App Store

`AppStore/` holds everything for App Store Connect: listing text
(`metadata.md`, checked by `check-metadata.py`), App Privacy, age rating,
export compliance and review notes, the screenshots, and
[`checklist.md`](AppStore/checklist.md), the steps only the account holder can
do (agreements, CloudKit Production schema, App ID capabilities, upload).

The privacy policy and support pages are static HTML in `docs/`, published with
GitHub Pages (branch `main`, folder `/docs`). `AppConfig.privacyPolicyURL` and
`AppConfig.supportURL` point at them, and Settings → About links to both. The
privacy manifest is `MadrigalChat/PrivacyInfo.xcprivacy`.

### Screenshots

```
AppStore/capture-screenshots.sh          # or: ios | mac
```

Debug builds have a screenshot demo mode, `ScreenshotDemo.swift`, turned on by
the launch arguments `-ScreenshotDemo YES -DemoScreen <chat|sidebar|project|search|settings|newchat>`.
It opens an in-memory store without CloudKit, fills it with made-up chats,
projects, agents and providers, and opens the named screen. Real data, the
Keychain and iCloud are never touched, and none of it is compiled into Release
builds. The script runs headless (`xcodebuild` and `simctl`, never Simulator.app)
for the iPhone 17 Pro Max (1320 × 2868) and the iPad Pro 13" (2064 × 2752).
The Mac shots (2880 × 1800) need Screen Recording permission for your terminal.

## License

Madrigal is source-available under the
[PolyForm Noncommercial License 1.0.0](LICENSE):

- You may read, build and change the source for personal and other
  noncommercial use. Selling it, or distributing builds of it, isn't allowed.
- The name "Madrigal" and the app icon aren't licensed for reuse.
- Third-party packages keep their own licenses: MLX Swift (MIT), and Hugging
  Face swift-transformers, swift-huggingface and the other Swift packages
  (Apache 2.0).

## Known rough edges

- Custom instructions in Settings are per device (UserDefaults), not synced.
- Context limits are counted in characters, not tokens. Lower a provider's
  context limit for small-context models.
