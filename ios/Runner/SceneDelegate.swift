import Flutter
import UIKit
import UserNotifications

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

    // Registra plugin PRIMA di creare il ViewController
    GeneratedPluginRegistrant.register(with: engine)
    print("[NATIVE-CALLKIT] SceneDelegate: Flutter engine + CallKit plugin registered here; VoIP PushKit delivery still goes to AppDelegate.pushRegistry (not SceneDelegate)")

    // Mantieni riferimento forte al canale eventi CallKit
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.callkitEventChannel = FlutterEventChannel(
        name: "flutter_callkit_incoming_events",
        binaryMessenger: engine.binaryMessenger
      )
      print("[NATIVE-CALLKIT] SceneDelegate: FlutterEventChannel flutter_callkit_incoming_events created (plugin registers stream handler on same engine at startup)")
    }

    // Setup canali
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
      // Stesso binaryMessenger del FlutterViewController: senza handler → MissingPluginException da Dart.
      appDelegate.voipChannel?.setMethodCallHandler { [weak appDelegate] call, result in
        appDelegate?.handleVoipMethodCall(call, result: result)
      }
      appDelegate.apnsChannel = FlutterMethodChannel(
        name: "com.axphone.app/apns",
        binaryMessenger: engine.binaryMessenger
      )
      appDelegate.apnsChannel?.setMethodCallHandler { [weak appDelegate] call, result in
        switch call.method {
        case "requestPermissions":
          UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
          ) { granted, _ in
            DispatchQueue.main.async { result(granted) }
          }
        case "getApnsToken":
          if let token = appDelegate?.pendingApnsToken {
            result(token)
          } else {
            UIApplication.shared.registerForRemoteNotifications()
            var waited = 0
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak appDelegate] timer in
              waited += 1
              if let token = appDelegate?.pendingApnsToken {
                timer.invalidate()
                DispatchQueue.main.async { result(token) }
              } else if waited >= 6 {
                timer.invalidate()
                DispatchQueue.main.async { result(nil) }
              }
            }
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      let chatChannel = FlutterMethodChannel(
        name: "com.axphone.app/chat",
        binaryMessenger: engine.binaryMessenger
      )
      chatChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "setActiveConversation":
          AppDelegate.activeConversationId = call.arguments as? String
          result(nil)
        case "clearActiveConversation":
          AppDelegate.activeConversationId = nil
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
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
