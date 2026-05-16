import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct FoundryProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .foundry

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "discovery" }
    }

    @MainActor
    func observeSettings(_: SettingsStore) {
        // No persisted settings in Phase 1. Auto-discovery only.
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        !FoundrySettingsReader.discoverDeployments(environment: context.environment).isEmpty
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }
}
