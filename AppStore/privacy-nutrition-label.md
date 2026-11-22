# App Privacy ("nutrition label") answers

App Store Connect → App Privacy → Get Started.

## Answer

**Do you or your third-party partners collect data from this app?** → **No, we do not collect data from this app.**

The label then reads **Data Not Collected**.

## Why that's the correct answer

Apple defines "collect" as transmitting data off the device in a way that lets
*you (the developer) or your third-party partners* access it for longer than
needed to service the request in real time. None of Madrigal's network traffic
meets that definition:

| Data leaves the device to | Who controls it | Why it isn't "collected" |
|---|---|---|
| The AI provider the user adds (OpenAI, OpenRouter, Cloudflare, their own server...) | The user, with their own account and key | The user chooses and configures the service directly. The developer has no account, no relationship and no access. Apple's guidance excludes data sent to a service at the user's direction that the developer can't access. |
| Hugging Face (model downloads) | Hugging Face | Only the model name; it's a file download, like a browser fetching a file. No user data. |
| DuckDuckGo, Wikipedia, Brave, the user's SearXNG, result web pages, Open-Meteo (optional web search) | Those services | Off by default; queries go straight from the device to services the user turns on. The developer receives nothing. |
| iCloud (CloudKit private database, iCloud Keychain) | The user's Apple Account | Apple's guidance: data in the user's private CloudKit database that the developer can't access is not collected. |

What the app does **not** have: analytics or crash-reporting SDKs, advertising,
tracking, accounts, a developer-run server, or any third-party SDK that phones
home. The linked Swift packages (MLX, swift-transformers, swift-huggingface,
EventSource, swift-crypto) only run locally or make the Hugging Face downloads
described above.

`MadrigalChat/PrivacyInfo.xcprivacy` agrees: `NSPrivacyTracking` false, no
tracking domains, no collected data types. Its required-reason API entries
(UserDefaults `CA92.1`, file timestamps `C617.1`, disk space `E174.1`) are
about local API use, not data collection.

## Tracking
**Does this app track users?** → **No.** Nothing is linked with third-party data
for advertising, and no data is shared with data brokers. No App Tracking
Transparency prompt is needed.

## Keep in sync
If a future version adds analytics, crash reporting, a developer-run server,
or a sync service other than the user's own iCloud, revisit this file, the
privacy policy (`docs/privacy.html`), `DataDisclosure.swift`, and the manifest.
