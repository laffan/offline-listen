import CarPlay

/// Entry point for the CarPlay scene. iOS instantiates this (on the main thread)
/// when the app connects to a CarPlay head unit, per the `UIApplicationSceneManifest`
/// in `Info.plist`. It owns a `CarPlayController` for the life of the connection
/// and hands it the interface controller used to set templates.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        // CarPlay scene delegate callbacks are delivered on the main thread.
        MainActor.assumeIsolated {
            let controller = CarPlayController()
            controller.connect(interfaceController)
            self.controller = controller
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            controller?.disconnect()
            controller = nil
        }
    }
}
