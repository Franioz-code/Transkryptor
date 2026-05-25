import SwiftUI
import SwiftData

@main
struct TranskryptorApp: App {
    @State private var appModel = AppModel()
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Lecture.self)
        } catch {
            fatalError("Nie udało się utworzyć magazynu danych: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .frame(minWidth: 720, minHeight: 480)
        }
        .modelContainer(container)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 820)

        Settings {
            SettingsView()
                .environment(appModel)
                .frame(width: 540)
        }
    }
}

/// Decyduje między onboardingiem a głównym widokiem; podpina kontekst SwiftData.
struct RootView: View {
    @AppStorage(SettingsKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                ContentView()
            } else {
                OnboardingView()
            }
        }
        .onAppear { appModel.modelContext = modelContext }
        .task(id: hasCompletedOnboarding) {
            if hasCompletedOnboarding {
                appModel.recoverInterruptedSessions()
                appModel.showIndicator()
                await appModel.prepareModelOnLaunch()
            }
        }
    }
}
