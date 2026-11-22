# Export compliance

**Answer in App Store Connect:** the app uses only encryption that is exempt.
No documentation needs to be uploaded.

- `ITSAppUsesNonExemptEncryption` is already `false` in `MadrigalChat/Info.plist`,
  so App Store Connect doesn't ask the encryption questions on each upload.
- The only encryption is standard and provided by Apple's operating system:
  HTTPS/TLS through `URLSession` to AI providers, Hugging Face and search
  services; the Keychain; and iCloud/CloudKit.
- swift-crypto is linked only as a dependency of the Hugging Face libraries,
  for hashing (verifying downloaded files), not for encrypting data.
- No proprietary or non-standard algorithms, no VPN, no end-to-end encrypted messaging.

This falls under the exemption for apps that use only encryption built into
the operating system, or standard encryption for authentication and HTTPS
(Category 5, Part 2, note 4 / mass-market exemptions). No year-end
self-classification report is needed for this exemption. If a future version
adds its own encryption (for example, encrypting chats with a user password),
revisit this answer.
