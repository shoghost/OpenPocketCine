import os
import UIKit

enum StreamingOrientationPolicy {
    static func supportedOrientations(streaming: Bool, idiom: UIUserInterfaceIdiom)
        -> UIInterfaceOrientationMask
    {
        if streaming { return .landscape }
        return idiom == .pad ? .all : .allButUpsideDown
    }
}

@MainActor
enum StreamingOrientationController {
    private static let log = Logger(
        subsystem: "com.opencapture.openpocketcine", category: "orientation")
    private(set) static var streaming = false

    static func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        let idiom = window?.traitCollection.userInterfaceIdiom
            ?? UIDevice.current.userInterfaceIdiom
        return StreamingOrientationPolicy.supportedOrientations(
            streaming: streaming, idiom: idiom)
    }

    /// Update both UIKit's supported-orientation gate and the active scene geometry. This is the
    /// public iOS 17 path; do not replace it with UIDevice KVC orientation writes.
    static func apply(enabled: Bool, scene suppliedScene: UIWindowScene? = nil) {
        streaming = enabled
        guard let scene = suppliedScene ?? activeWindowScene() else {
            log.info("orientation: policy updated; no foreground scene yet")
            return
        }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        let idiom = scene.traitCollection.userInterfaceIdiom
        let mask = StreamingOrientationPolicy.supportedOrientations(
            streaming: enabled, idiom: idiom)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            log.error(
                "orientation: geometry update failed domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public) description=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
    }
}

@MainActor
final class OpenPocketCineAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        StreamingOrientationController.supportedOrientations(for: window)
    }
}
