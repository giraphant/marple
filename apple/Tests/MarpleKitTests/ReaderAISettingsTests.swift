import Foundation
import Testing
@testable import Marple
import MarpleKit

struct ReaderAISettingsTests {
    @Test func taskSettingsKeepLegacyDefaultsAndRemainIndependent() throws {
        let suite = "ReaderAISettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = [
            SettingsKeys.readerAIAgent: "claude --model opus",
            SettingsKeys.aiAgentChoice: "custom",
            SettingsKeys.aiDispatchTarget: "orca",
            SettingsKeys.aiDispatchTemplate: AIDispatchTarget.orca.defaultTemplate,
            SettingsKeys.supersetWorkspaceID: "existing-workspace",
            SettingsKeys.supersetCLIPath: "/opt/homebrew/bin/superset",
        ]
        for (key, value) in legacy {
            defaults.set(value, forKey: key)
            for action in ReaderAIAction.allCases {
                #expect(SettingsKeys.readerAIValue(key, for: action, defaults: defaults) == value)
            }
            defaults.set("translation-only", forKey: SettingsKeys.readerAIKey(key, for: .translate))
            #expect(SettingsKeys.readerAIValue(key, for: .translate, defaults: defaults) == "translation-only")
            #expect(SettingsKeys.readerAIValue(key, for: .discuss, defaults: defaults) == value)
            #expect(defaults.string(forKey: key) == value)
        }

        // Clearing an override must not silently revive the legacy value.
        defaults.set("", forKey: SettingsKeys.readerAIKey(SettingsKeys.readerAIAgent, for: .translate))
        #expect(SettingsKeys.readerAIValue(SettingsKeys.readerAIAgent, for: .translate, defaults: defaults) == "")
        #expect(Set(ReaderAIAction.allCases.map { SettingsKeys.readerAIPromptKey(for: $0) }).count == 4)
        #expect(SettingsKeys.readerAIPromptKey(for: .translate) == SettingsKeys.readerAITranslatePrompt)
    }
}
