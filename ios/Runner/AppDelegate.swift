import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let contactPickerPlugin = ContactPickerPlugin()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    registerContactChannel()
  }

  private var contactChannelRegistered = false
  private func registerContactChannel() {
    guard !contactChannelRegistered else { return }
    // Cerca il FlutterViewController in tutta la gerarchia
    var vc = window?.rootViewController
    while let presented = vc?.presentedViewController {
      vc = presented
    }
    guard let flutterVC = findFlutterViewController(vc) else { return }
    contactChannelRegistered = true
    let channel = FlutterMethodChannel(
      name: "com.securechat/contacts",
      binaryMessenger: flutterVC.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] (call, result) in
      self?.contactPickerPlugin.handle(call, result: result)
    }
  }

  private func findFlutterViewController(_ vc: UIViewController?) -> FlutterViewController? {
    if let flutter = vc as? FlutterViewController { return flutter }
    for child in vc?.children ?? [] {
      if let found = findFlutterViewController(child) { return found }
    }
    return nil
  }
}
