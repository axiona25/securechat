import Flutter
import UIKit
import AudioToolbox
import PushKit
import FirebaseCore
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, FlutterImplicitEngineDelegate {
  var ringtoneTimer: Timer?
  var voipChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    application.registerForRemoteNotifications()
    let voipRegistry = PKPushRegistry(queue: .main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [.voIP]
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()

    let soundsChannel = FlutterMethodChannel(
      name: "com.axphone.app/sounds",
      binaryMessenger: messenger
    )
    soundsChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "playSystemRingtone": self?.playSystemRingtone(); result(nil)
      case "stopSystemRingtone": self?.stopSystemRingtone(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }

    voipChannel = FlutterMethodChannel(
      name: "com.axphone.app/voip",
      binaryMessenger: messenger
    )
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let tokenString = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
    DispatchQueue.main.async { [weak self] in
      self?.voipChannel?.invokeMethod("voipTokenReceived", arguments: tokenString)
    }
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    guard type == .voIP else { completion(); return }
    let dict = payload.dictionaryPayload
    let handle = (dict["handle"] as? String) ?? (dict["callerName"] as? String) ?? ""
    let callerName = (dict["callerName"] as? String) ?? handle
    let callId = (dict["callId"] as? String) ?? ""
    let callType = (dict["callType"] as? String) ?? "audio"
    let callerUserId = (dict["callerUserId"] as? String) ?? ""
    let conversationId = (dict["conversationId"] as? String) ?? ""
    let args: [String: Any] = [
      "handle": handle, "callerName": callerName, "callId": callId,
      "callType": callType, "callerUserId": callerUserId, "conversationId": conversationId
    ]
    DispatchQueue.main.async { [weak self] in
      self?.voipChannel?.invokeMethod("incomingCall", arguments: args)
    }
    completion()
  }

  func playSystemRingtone() {
    stopSystemRingtone()
    AudioServicesPlaySystemSound(1005)
    ringtoneTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
      AudioServicesPlaySystemSound(1005)
    }
    RunLoop.main.add(ringtoneTimer!, forMode: .common)
  }

  func stopSystemRingtone() {
    ringtoneTimer?.invalidate()
    ringtoneTimer = nil
  }
}
