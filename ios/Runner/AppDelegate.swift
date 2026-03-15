import Flutter
import UIKit
import AudioToolbox
import PushKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, FlutterImplicitEngineDelegate {
  var ringtoneTimer: Timer?
  var voipChannel: FlutterMethodChannel?
  var apnsChannel: FlutterMethodChannel?
  var pendingApnsToken: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.registerForRemoteNotifications()
    UNUserNotificationCenter.current().delegate = self
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

    apnsChannel = FlutterMethodChannel(
      name: "com.axphone.app/apns",
      binaryMessenger: messenger
    )
    apnsChannel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "requestPermissions":
        UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .badge, .sound]
        ) { granted, _ in
          DispatchQueue.main.async { result(granted) }
        }
      case "getApnsToken":
        if let token = self?.pendingApnsToken {
          result(token)
        } else {
          UIApplication.shared.registerForRemoteNotifications()
          // Attendi fino a 3 secondi che il token arrivi
          var waited = 0
          Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            waited += 1
            if let token = self?.pendingApnsToken {
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
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    pendingApnsToken = tokenString
    DispatchQueue.main.async { [weak self] in
      self?.apnsChannel?.invokeMethod("apnsTokenReceived", arguments: tokenString)
    }
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    print("[APNs] Registrazione fallita: \(error)")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let tokenString = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
    DispatchQueue.main.async { [weak self] in
      self?.voipChannel?.invokeMethod("voipTokenReceived", arguments: tokenString)
    }
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
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

  // Mostra notifica anche in foreground
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .badge, .sound])
    } else {
      completionHandler([.alert, .badge, .sound])
    }
  }

  // Gestisce tap sulla notifica
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    if let conversationId = userInfo["conversation_id"] as? String {
      DispatchQueue.main.async { [weak self] in
        self?.apnsChannel?.invokeMethod("notificationTapped", arguments: conversationId)
      }
    }
    completionHandler()
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
