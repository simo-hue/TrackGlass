import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let controller = TouchSurfaceViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
        for context in connectionOptions.urlContexts { controller.handlePairingURL(context.url) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let controller = window?.rootViewController as? TouchSurfaceViewController else { return }
        for context in URLContexts { controller.handlePairingURL(context.url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let controller = window?.rootViewController as? TouchSurfaceViewController else { return }
        controller.updateIdleTimer()
        controller.sceneDidBecomeActive()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (window?.rootViewController as? TouchSurfaceViewController)?.sceneDidEnterBackground()
    }
}
