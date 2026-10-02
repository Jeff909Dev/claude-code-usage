import SwiftUI
import UsageCore

@main
struct ClaudeUsageApp: App {
    @State private var model: AppModel

    init() {
        // --read-only never refreshes a token or writes a login, and keeps the app's own files in a scratch folder.
        let readOnly = CommandLine.arguments.contains("--read-only")
        let env: CoreEnvironment
        do { env = try CoreEnvironment.live(readOnly: readOnly) } catch {
            fatalError("Cannot create the Application Support folder: \(error)")
        }
        let model = AppModel(env: env, readOnly: readOnly, poster: NotificationPosterFactory.make(readOnly: readOnly))
        _model = State(initialValue: model)
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environment(model)
                .environment(\.themeStyle, model.settings.style)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        } label: {
            Text(model.menuBarTitle)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}
