# Submission checklist: steps only you can do

In order. Everything else (metadata, privacy pages, manifest, screenshots) is in this folder.

## 1. Agreements and money (blocks a paid app)
- [x] App Store Connect → Business: accept the **Paid Apps Agreement**.
- [x] Add **bank account** and **tax forms** (W-9, plus others the form asks for). Status must read *Active* before a $1.99 app can go on sale.

## 2. Make the URLs live
The site is published from the public, docs-only repo `cwhittl/madrigal`. The app source stays private in `cwhittl/zero-chat`. `docs/` in this repo is the source of truth. The site files sit at the root of the madrigal repo, so the URLs below don't change.
- [x] `docs/` contents, `LICENSE` and a README pushed to `cwhittl/madrigal` (`main`).
- [ ] github.com/cwhittl/madrigal → Settings → Pages → Build and deployment → **Deploy from a branch** → `main`, folder **`/ (root)`** → Save.
- [ ] To republish after editing `docs/`: clone `cwhittl/madrigal`, copy `docs/.` over its root (`rsync -a --exclude .DS_Store docs/ ../madrigal/`), commit, push.
- [ ] After a minute or two, open these and check they load:
  - https://cwhittl.github.io/madrigal/
  - https://cwhittl.github.io/madrigal/privacy.html
  - https://cwhittl.github.io/madrigal/support.html

## 3. Apple Developer: App ID and CloudKit
- [x] Certificates, Identifiers & Profiles → Identifiers → `dev.whittle.madrigalchat`. Enable:
  - iCloud (CloudKit) with container `iCloud.dev.whittle.madrigalchat`
  - Push Notifications
  - Increased Memory Limit
  - Extended Virtual Addressing
  - Background GPU access for continued processing (`com.apple.developer.background-tasks.continued-processing.gpu`)
- [x] Run a Debug build against Development once so every record type and field exists, then CloudKit Console → **Deploy Schema Changes** to **Production**.
- [x] `aps-environment`: nothing to edit. Xcode sets it to `production` when it re-signs for distribution. The archive itself stays development-signed and still says `development`, so check an export instead: `xcodebuild -exportArchive` with `method` `app-store-connect` and `destination` `export`, then `plutil -p <export>/DistributionSummary.plist | grep aps-environment`. It lists every entitlement, so it also confirms the capabilities above.

## 4. App Store Connect record
- [x] New App → platforms **iOS** and **macOS**, name "Madrigal – AI Chat", bundle ID `dev.whittle.madrigalchat`, SKU e.g. `madrigal-1`.
- [ ] Fill in `metadata.md` fields; run `python3 AppStore/check-metadata.py` after any edits.
- [ ] App Privacy: answers in `privacy-nutrition-label.md` (Data Not Collected).
- [ ] Age rating: `age-rating.md`.
- [ ] Pricing: $1.99, all countries and regions.
- [ ] Review notes: `review-notes.md`, with a real spend-capped OpenRouter key pasted in App Store Connect only.
- [ ] Screenshots: upload `screenshots/iphone-6.3` (the 6.1"/6.3" slot), `screenshots/iphone-6.9`, `screenshots/ipad-13`, `screenshots/mac`.
- [ ] iOS 27 placements (optional): upload `promo/header.png` (product page header, 3840×1646) and `promo/search-results.png` (search results, 3840×2560). Regenerate with `swift AppStore/make-promo-art.swift`.

## 5. Build, upload, test
- [ ] Xcode → Product → Archive with an **Any iOS Device** destination → Distribute → App Store Connect.
- [ ] Same for **My Mac** (macOS archive).
- [ ] TestFlight on iPhone, iPad and Mac. With two devices on one iCloud account, confirm chats sync and keys arrive through iCloud Keychain.
- [ ] Submit both platforms for review together.

## 6. After approval
- [ ] Revoke the review OpenRouter key.
