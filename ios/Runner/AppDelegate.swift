import Flutter
import UIKit
import AudioToolbox
import PushKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  private var ringtoneTimer: Timer?
  private weak var flutterController: FlutterViewController?
  private var voipChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    flutterController = controller

    let soundsChannel = FlutterMethodChannel(name: "com.axphone.app/sounds", binaryMessenger: controller.binaryMessenger)
    soundsChannel.setMethodCallHandler { [weak self] (call, result) in
      if call.method == "playSystemRingtone" {
        self?.playSystemRingtone()
        result(nil)
      } else if call.method == "stopSystemRingtone" {
        self?.stopSystemRingtone()
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let voipChannel = FlutterMethodChannel(name: "com.axphone.app/voip", binaryMessenger: controller.binaryMessenger)
    self.voipChannel = voipChannel

    let voipRegistry = PKPushRegistry(queue: .main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [.voIP]

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
      "handle": handle,
      "callerName": callerName,
      "callId": callId,
      "callType": callType,
      "callerUserId": callerUserId,
      "conversationId": conversationId
    ]
    DispatchQueue.main.async { [weak self] in
      self?.voipChannel?.invokeMethod("incomingCall", arguments: args)
    }
    completion()
  }

  private func playSystemRingtone() {
    stopSystemRingtone()
    AudioServicesPlaySystemSound(1005)
    ringtoneTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
      AudioServicesPlaySystemSound(1005)
    }
    RunLoop.main.add(ringtoneTimer!, forMode: .common)
  }

  private func stopSystemRingtone() {
    ringtoneTimer?.invalidate()
    ringtoneTimer = nil
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
