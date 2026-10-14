import SwiftUI
import SwiftData
import UIKit

@main
struct ApexApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.orange)
        }
        .modelContainer(Persistence.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Also runs when iOS relaunches the app in the background for a
        // location event, so drive detection starts here, not in a view.
        LocationService.shared.start()
        Persistence.ensureCar()
        Persistence.syncActiveCarToWidget()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationController.mask
    }
}

/// Locks the app to portrait, except during a live track session.
@MainActor
enum OrientationController {
    static var mask: UIInterfaceOrientationMask = .portrait

    static func lock(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { _ in }
        }
    }
}

enum AppTab: Hashable {
    case drives, tracks, garage
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SharedStore.Key.onboardingDone, store: SharedStore.defaults) private var onboardingDone = false
    @State private var tab: AppTab = .drives

    var body: some View {
        TabView(selection: $tab) {
            Tab("Fahrten", systemImage: "road.lanes", value: AppTab.drives) {
                DrivesView()
            }
            Tab("Strecken", systemImage: "flag.checkered", value: AppTab.tracks) {
                TracksView()
            }
            Tab("Garage", systemImage: "car.side.fill", value: AppTab.garage) {
                GarageView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .fullScreenCover(isPresented: Binding(get: { !onboardingDone }, set: { onboardingDone = !$0 })) {
            OnboardingView {
                onboardingDone = true
            }
        }
        .onOpenURL { url in
            switch url.host() {
            case "garage": tab = .garage
            case "tracks": tab = .tracks
            default: tab = .drives
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                LocationService.shared.appBecameActive()
            }
        }
    }
}
