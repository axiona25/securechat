import Flutter
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

  var window: UIWindow?
  private var flutterEngine: FlutterEngine?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let engine = FlutterEngine(name: "io.flutter")
    engine.run()
    flutterEngine = engine

    GeneratedPluginRegistrant.register(with: engine)

    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      let soundsChannel = FlutterMethodChannel(
        name: "com.axphone.app/sounds",
        binaryMessenger: engine.binaryMessenger
      )
      soundsChannel.setMethodCallHandler { [weak appDelegate] (call, result) in
        switch call.method {
        case "playSystemRingtone": appDelegate?.playSystemRingtone(); result(nil)
        case "stopSystemRingtone": appDelegate?.stopSystemRingtone(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
      appDelegate.voipChannel = FlutterMethodChannel(
        name: "com.axphone.app/voip",
        binaryMessenger: engine.binaryMessenger
      )
    }

    let vc = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = vc
    window.makeKeyAndVisible()
    self.window = window
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    flutterEngine?.destroyContext()
    flutterEngine = nil
  }
}
