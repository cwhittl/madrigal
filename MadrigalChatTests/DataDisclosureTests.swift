import Foundation
import Testing
@testable import Madrigal

/// Keeps the "Your Data" screen in step with what the app actually sends.
/// If one of these fails after a change, update `DataDisclosure` rather
/// than the test.
@MainActor
struct DataDisclosureTests {
    private func covering(_ recipient: DataRecipient, cloudSync: Bool) -> [DataDisclosure.Point] {
        DataDisclosure.points(cloudSync: cloudSync).filter { $0.recipients.contains(recipient) }
    }

    @Test(arguments: [true, false])
    func everyRecipientIsDisclosedByName(cloudSync: Bool) {
        for recipient in DataRecipient.allCases {
            // Without sync nothing goes to iCloud, so there's nothing to disclose.
            if recipient == .iCloud && !cloudSync { continue }
            let points = covering(recipient, cloudSync: cloudSync)
            #expect(!points.isEmpty, "No disclosure point covers \(recipient)")
            for point in points {
                #expect(point.text.contains(recipient.disclosedName),
                        "\"\(point.title)\" claims to cover \(recipient) but never says \"\(recipient.disclosedName)\"")
            }
        }
    }

    @Test func iCloudIsOnlyMentionedWhenSyncIsOn() {
        #expect(covering(.iCloud, cloudSync: false).isEmpty)
        let text = DataDisclosure.points(cloudSync: false).map(\.text).joined()
        #expect(!text.contains("iCloud"))
    }

    @Test func defaultPointsFollowTheSyncSetting() {
        let expected = DataDisclosure.points(cloudSync: AppConfig.enableCloudKitSync).map(\.text)
        #expect(DataDisclosure.points().map(\.text) == expected)
    }

    @Test func onDeviceKindsMatchTheText() {
        let onDevice = Set(ProviderKind.allCases.filter { $0.chatRecipient == nil })
        #expect(onDevice == DataDisclosure.onDeviceKinds,
                "\"Who receives it\" names Apple Intelligence and downloaded models as the on-device options")
    }

    @Test func webSearchIsOnlyForOnDeviceKinds() {
        // The web search point says it's for on-device models only.
        for kind in ProviderKind.allCases {
            let config = ProviderConfig()
            config.kind = kind
            if config.supportsWebSearch {
                #expect(DataDisclosure.onDeviceKinds.contains(kind), "\(kind) can search but isn't on-device")
            }
        }
    }

    @Test func webSearchQueryLimitIsStated() {
        let point = DataDisclosure.points().first { $0.recipients.contains(.searxng) }
        #expect(point?.text.contains("\(WebSearchConfig.queryCharacterLimit) characters") == true)
    }

    @Test func hostedExamplesAreHostedPresets() {
        for name in DataDisclosure.hostedExamples {
            let preset = ProviderPreset.all.first { $0.name == name }
            #expect(preset != nil, "No preset named \(name)")
            #expect(preset?.kind.chatRecipient == .chatProvider, "\(name) isn't a hosted provider")
        }
    }

    @Test func modelDownloadsGoToHuggingFace() {
        #expect(LocalModelStore.hubHost.host() == "huggingface.co",
                "Model downloads moved off Hugging Face; update the Model downloads point")
    }

    @Test func pointTitlesAreUnique() {
        // Titles are the ForEach identity.
        let titles = DataDisclosure.points().map(\.title)
        #expect(Set(titles).count == titles.count)
    }
}
