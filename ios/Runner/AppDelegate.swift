import Flutter
import UIKit
import AudioToolbox

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var ringtoneTimer: Timer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    let channel = FlutterMethodChannel(name: "com.axphone.app/sounds", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self] (call, result) in
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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func playSystemRingtone() {
    stopSystemRingtone()
    // System sound 1005 = Phone Ringing; repeat to simulate ringtone
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
