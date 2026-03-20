import Flutter
import UIKit
import AudioToolbox
import AVFoundation
import PushKit
import UserNotifications
import CallKit
import WebRTC
import flutter_callkit_incoming

/// `flutter_callkit_incoming` controlla `CXAnswerCallAction` così:
/// se `UIApplication.shared.delegate` è `CallkitIncomingAppDelegate`, deve essere **l'app** a chiamare `action.fulfill()`.
/// Senza conformità esplicita il cast fallisce, il plugin fa solo `print("does NOT conform")` e l'handoff WebRTC in
/// `didActivateAudioSession` non viene mai invocato (solo la notifica duplicata).
@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CallkitIncomingAppDelegate {
  var ringtoneTimer: Timer?
  var voipChannel: FlutterMethodChannel?
  var apnsChannel: FlutterMethodChannel?
  var pendingApnsToken: String?
  /// Riferimento forte al canale eventi CallKit (evita deallocazione dell'handler in WeakArray)
  var callkitEventChannel: FlutterEventChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.registerForRemoteNotifications()
    UNUserNotificationCenter.current().delegate = self
    let voipRegistry = PKPushRegistry(queue: .main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [.voIP]
    // WebRTC manual audio: CallKit attiva la sessione; notifichiamo RTC in `didActivateAudioSession`.
    RTCAudioSession.sharedInstance().useManualAudio = true
    RTCAudioSession.sharedInstance().isAudioEnabled = false
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - CallkitIncomingAppDelegate (flutter_callkit_incoming)

  public func onAccept(_ call: Call, _ action: CXAnswerCallAction) {
    print("[NATIVE-AUDIO] CallkitIncomingAppDelegate.onAccept uuid=\(call.uuid) — fulfilling CXAnswerCallAction")
    action.fulfill()
  }

  public func onDecline(_ call: Call, _ action: CXEndCallAction) {
    print("[NATIVE-AUDIO] CallkitIncomingAppDelegate.onDecline uuid=\(call.uuid)")
    action.fulfill()
  }

  public func onEnd(_ call: Call, _ action: CXEndCallAction) {
    print("[NATIVE-AUDIO] CallkitIncomingAppDelegate.onEnd uuid=\(call.uuid)")
    action.fulfill()
  }

  public func onTimeOut(_ call: Call) {
    print("[NATIVE-AUDIO] CallkitIncomingAppDelegate.onTimeOut uuid=\(call.uuid)")
  }

  /// Dizionario per Dart (`getAudioRouteSnapshot` / `forceSpeakerOnDebug` ritorno).
  /// - Parameter logRouteSnapshotRequest: se true, stampa la riga diagnostica richiesta da Dart.
  func avAudioRouteSnapshotDict(logRouteSnapshotRequest: Bool) -> [String: Any] {
    let s = AVAudioSession.sharedInstance()
    let outs = s.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
    let ins = s.currentRoute.inputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
    if logRouteSnapshotRequest {
      print(
        "[NATIVE-AUDIO] route snapshot request category=\(s.category.rawValue) mode=\(s.mode.rawValue) outputs=[\(outs)] inputs=[\(ins)]"
      )
    }
    var dict: [String: Any] = [
      "category": s.category.rawValue,
      "mode": s.mode.rawValue,
      "outputs": outs,
      "inputs": ins,
      "sampleRate": s.sampleRate,
      "ioBufferDuration": s.ioBufferDuration,
      "isOtherAudioPlaying": s.isOtherAudioPlaying,
    ]
    if #available(iOS 14.0, *) {
      dict["secondaryAudioShouldBeSilencedHint"] = s.secondaryAudioShouldBeSilencedHint
    } else {
      dict["secondaryAudioShouldBeSilencedHint"] = NSNull()
    }
    return dict
  }

  /// Debug: allinea voce, forza uscita speaker, log PRE/POST, ritorna snapshot finale (senza duplicare `route snapshot request`).
  func runForceSpeakerOnDebug() -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    logAvAudioSessionSnapshot("forceSpeakerOnDebug PRE", session: session)

    if session.category != .playAndRecord || session.mode != .voiceChat {
      do {
        try session.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.allowBluetooth, .allowBluetoothA2DP]
        )
        print("[NATIVE-AUDIO] forceSpeakerOnDebug aligned category=playAndRecord mode=voiceChat")
      } catch {
        print("[NATIVE-AUDIO] forceSpeakerOnDebug setCategory/mode FAILED: \(error)")
      }
    }

    do {
      try session.overrideOutputAudioPort(.speaker)
      print("[NATIVE-AUDIO] forceSpeakerOnDebug overrideOutputAudioPort(.speaker) OK")
    } catch {
      print("[NATIVE-AUDIO] forceSpeakerOnDebug overrideOutputAudioPort FAILED: \(error)")
    }

    logAvAudioSessionSnapshot("forceSpeakerOnDebug POST", session: session)
    return avAudioRouteSnapshotDict(logRouteSnapshotRequest: false)
  }

  /// Handler condiviso tra `didInitializeImplicitFlutterEngine` e `SceneDelegate` (stesso engine effettivo = Scene).
  func handleVoipMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configureAudioForWebRTC":
      configureAudioForWebRTC()
      result(nil)
    case "getAudioRouteSnapshot":
      result(avAudioRouteSnapshotDict(logRouteSnapshotRequest: true))
    case "forceSpeakerOnDebug":
      result(runForceSpeakerOnDebug())
    case "retriggerAudioEnabled":
      let rtc = RTCAudioSession.sharedInstance()
      print("[AUDIO-RETRIGGER] PRE isAudioEnabled=\(rtc.isAudioEnabled)")
      rtc.lockForConfiguration()
      rtc.isAudioEnabled = false
      rtc.isAudioEnabled = true
      rtc.unlockForConfiguration()
      print("[AUDIO-RETRIGGER] POST isAudioEnabled=\(rtc.isAudioEnabled)")
      result(["success": true, "isAudioEnabled": rtc.isAudioEnabled])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Snapshot diagnostico AVAudioSession (CallKit → WebRTC handoff).
  private func logAvAudioSessionSnapshot(_ label: String, session: AVAudioSession) {
    let outs = session.currentRoute.outputs
      .map { "\($0.portType.rawValue)" }
      .joined(separator: ",")
    let ins = session.currentRoute.inputs
      .map { "\($0.portType.rawValue)" }
      .joined(separator: ",")
    let hint: String
    if #available(iOS 14.0, *) {
      hint = "\(session.secondaryAudioShouldBeSilencedHint)"
    } else {
      hint = "n/a"
    }
    print(
      "[NATIVE-AUDIO] \(label) category=\(session.category) mode=\(session.mode) isOtherAudioPlaying=\(session.isOtherAudioPlaying) outputs=[\(outs)] inputs=[\(ins)] sampleRate=\(session.sampleRate) ioBufferDuration=\(session.ioBufferDuration) secondaryAudioShouldBeSilencedHint=\(hint)"
    )
  }

  public func didActivateAudioSession(_ audioSession: AVAudioSession) {
    logAvAudioSessionSnapshot("didActivate PRE (before category/mode fix + RTC handoff)", session: audioSession)

    // CallKit può attivare la sessione come Playback/Default; WebRTC voce richiede playAndRecord + voiceChat.
    // Nessun setActive qui: la sessione è già attiva da CallKit.
    let needsFix =
      audioSession.category != .playAndRecord || audioSession.mode != .voiceChat
    if needsFix {
      do {
        try audioSession.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.allowBluetooth, .allowBluetoothA2DP]
        )
        print("[NATIVE-AUDIO] didActivate aligned category=playAndRecord mode=voiceChat options=bluetooth+A2DP")
      } catch {
        print("[NATIVE-AUDIO] didActivate setCategory/mode FAILED (continuing handoff): \(error)")
      }
    } else {
      print("[NATIVE-AUDIO] didActivate skip category/mode fix (already playAndRecord + voiceChat)")
    }

    let rtc = RTCAudioSession.sharedInstance()
    rtc.lockForConfiguration()
    // Dopo allineamento sessione: notifica WebRTC e abilita audio unit (ordine raccomandato post-fix route).
    rtc.audioSessionDidActivate(audioSession)
    rtc.isAudioEnabled = true
    rtc.unlockForConfiguration()

    logAvAudioSessionSnapshot("didActivate POST (after RTC handoff)", session: audioSession)
    let useManual = rtc.useManualAudio
    let isEnabled = rtc.isAudioEnabled
    print("[NATIVE-AUDIO] didActivate RTC useManualAudio=\(useManual) isAudioEnabled=\(isEnabled)")
    print("[NATIVE-AUDIO] didActivateAudioSession — RTCAudioSession handoff complete (CallkitIncomingAppDelegate)")
  }

  public func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
    let rtc = RTCAudioSession.sharedInstance()
    rtc.lockForConfiguration()
    rtc.audioSessionDidDeactivate(audioSession)
    rtc.isAudioEnabled = false
    rtc.unlockForConfiguration()
    print("[NATIVE-AUDIO] didDeactivateAudioSession — WebRTC deactivated")
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

    // UIScene: `SceneDelegate` crea il motore UI e assegna `voip`/`apns` sul suo binaryMessenger.
    // Non sovrascrivere: altrimenti PushKit invierebbe su un engine diverso da quello di Dart.
    if voipChannel == nil {
      voipChannel = FlutterMethodChannel(
        name: "com.axphone.app/voip",
        binaryMessenger: messenger
      )
      voipChannel?.setMethodCallHandler { [weak self] call, result in
        self?.handleVoipMethodCall(call, result: result)
      }
    } else {
      print("[NATIVE-CALLKIT] didInitializeImplicitFlutterEngine: keep existing voipChannel (SceneDelegate engine)")
    }

    if apnsChannel == nil {
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
    } else {
      print("[NATIVE-CALLKIT] didInitializeImplicitFlutterEngine: keep existing apnsChannel (SceneDelegate engine)")
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
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
    print("[NATIVE-CALLKIT] PushKit VoIP credentials updated token.prefix16=\(tokenString.prefix(16))… (device registered for VoIP at OS level)")
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
    print("[NATIVE-CALLKIT] pushRegistry didReceiveIncomingPushWith for=\(String(describing: type)) (VoIP push path only if type==voIP)")
    guard type == .voIP else {
      print("[NATIVE-CALLKIT] skip: not a VoIP PushKit payload — CallKit will NOT be triggered here")
      completion()
      return
    }

    let dict           = payload.dictionaryPayload
    let handle         = (dict["handle"]          as? String) ?? (dict["callerName"] as? String) ?? "Sconosciuto"
    let callerName     = (dict["callerName"]       as? String) ?? handle
    let rawCallId      = (dict["callId"]           as? String) ?? UUID().uuidString
    let callType       = (dict["callType"]         as? String) ?? "audio"
    let callerUserId   = (dict["callerUserId"]     as? String) ?? ""
    let conversationId = (dict["conversationId"]   as? String) ?? ""

    // Stesso formato canonico di Dart (trim + lowercased) per allineare WS / bridge / plugin.
    let trimmed = rawCallId.trimmingCharacters(in: .whitespacesAndNewlines)
    let callId: String
    if trimmed.isEmpty {
      callId = UUID().uuidString.lowercased()
    } else {
      callId = trimmed.lowercased()
    }

    let payloadSummary = String(describing: dict)
    print("[NATIVE-CALLKIT] PushKit received callId=\(callId) payload=\(payloadSummary)")
    print("[NATIVE-CALLKIT] PushKit parsed callerName=\(callerName) handle=\(handle) callType=\(callType) (next: immediate main-thread path; no async before CallKit)")

    let typeInt = (callType.lowercased() == "video") ? 1 : 0
    let extraHeaders: [String: Any] = [
      "callerUserId": callerUserId,
      "callId": callId,
      "conversationId": conversationId,
      "callType": callType,
    ]

    /// Argomenti MethodChannel verso Flutter (stesso schema di prima + flag sync).
    let flutterArgs: [String: Any] = [
      "handle": handle,
      "callerName": callerName,
      "callId": callId,
      "callType": callType,
      "callerUserId": callerUserId,
      "conversationId": conversationId,
    ]

    // Apple: l'incoming call va postato senza deferire al run loop successivo (no main.async qui).
    let handleVoipPushOnMain: () -> Void = { [weak self] in
      guard let self = self else {
        print("[NATIVE-CALLKIT] ERROR self nil — cannot complete PushKit handling")
        completion()
        return
      }

      print("[NATIVE-CALLKIT] main-thread immediate path callId=\(callId) isMainThread=\(Thread.isMainThread)")

      let state = UIApplication.shared.applicationState
      let stateLabel: String
      switch state {
      case .active: stateLabel = "active(foreground)"
      case .inactive: stateLabel = "inactive"
      case .background: stateLabel = "background"
      @unknown default: stateLabel = "unknown"
      }
      print("[NATIVE-CALLKIT] UIApplication.applicationState=\(stateLabel) callId=\(callId)")

      if state == .active {
        // Foreground: trigger principale CallKit UI = Flutter (VoipService); nativo non usa showCallkitIncoming qui.
        print("[NATIVE-CALLKIT] PATH=foreground: PRIMARY for CallKit UI = Flutter MethodChannel (not native showCallkitIncoming) callId=\(callId)")
        let argsFg = flutterArgs.merging(["nativeCallKitShown": false]) { _, new in new }
        print("[NATIVE-CALLKIT] invokeMethod incomingCall to Flutter callId=\(callId) role=SECONDARY-ONLY-IF-DART-SHOWS-CALLKIT nativeCallKitShown=false")
        self.voipChannel?.invokeMethod("incomingCall", arguments: argsFg)
        let logMsg = "[AppDelegate] didReceiveIncomingPushWith: handle=\(handle) callerName=\(callerName) callId=\(callId) callType=\(callType)"
        self.voipChannel?.invokeMethod("remoteLog", arguments: logMsg)
        print("[NATIVE-CALLKIT] completion() called callId=\(callId) (foreground; PK after Flutter notify)")
        completion()
        return
      }

      guard let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance else {
        print("[NATIVE-CALLKIT] ERROR sharedInstance nil — PRIMARY native CallKit impossible; FALLBACK=Flutter callId=\(callId)")
        let argsFb = flutterArgs.merging(["nativeCallKitShown": false]) { _, new in new }
        print("[NATIVE-CALLKIT] invokeMethod incomingCall to Flutter callId=\(callId) role=FALLBACK-PRIMARY-IF-NATIVE-UNAVAILABLE nativeCallKitShown=false")
        self.voipChannel?.invokeMethod("incomingCall", arguments: argsFb)
        print("[NATIVE-CALLKIT] completion() called callId=\(callId) (plugin nil fallback)")
        completion()
        return
      }

      let activeBefore = plugin.activeCalls()
      print("[NATIVE-CALLKIT] pre-show active plugin calls count=\(activeBefore.count)")
      if !activeBefore.isEmpty {
        print("[NATIVE-CALLKIT] stale call cleanup start … (endAllCalls)")
        plugin.endAllCalls()
        print("[NATIVE-CALLKIT] stale call cleanup done count=\(activeBefore.count)")
      }
      let activeAfter = plugin.activeCalls()
      print("[NATIVE-CALLKIT] after cleanup callsInManager=\(activeAfter.count)")

      let iosParams: [String: Any] = [
        "iconName": "CallKitLogo",
        "configureAudioSession": false,
        "audioSessionActive": false,
        "supportsHolding": false,
        "supportsGrouping": false,
        "supportsUngrouping": false,
        "supportsDTMF": false,
      ]
      let ckArgs: [String: Any?] = [
        "id": callId,
        "nameCaller": callerName,
        "handle": handle,
        "type": typeInt,
        "duration": 45000,
        "appName": "AXPHONE",
        "avatar": "https://axphone.it/callkit_logo.png",
        "extra": extraHeaders as NSDictionary,
        "headers": extraHeaders as NSDictionary,
        "ios": iosParams,
      ]
      print("[NATIVE-CALLKIT] AppDelegate ckArgs ios=\(iosParams)")
      let data = flutter_callkit_incoming.Data(args: ckArgs)

      print("[NATIVE-CALLKIT] about to showCallkitIncoming(fromPushKit:true) callId=\(callId)")
      plugin.showCallkitIncoming(data, fromPushKit: true) {
        print("[NATIVE-CALLKIT] showCallkitIncoming plugin callback (after reportNewIncomingCall) callId=\(callId)")
        print("[NATIVE-CALLKIT] completion() PushKit callId=\(callId)")
        completion()
        let syncArgs = flutterArgs.merging(["nativeCallKitShown": true]) { _, new in new }
        print("[NATIVE-CALLKIT] invokeMethod incomingCall to Flutter callId=\(callId) role=AFTER-NATIVE-REPORT nativeCallKitShown=true")
        self.voipChannel?.invokeMethod("incomingCall", arguments: syncArgs)
        let logMsg = "[AppDelegate] didReceiveIncomingPushWith: handle=\(handle) callerName=\(callerName) callId=\(callId) callType=\(callType)"
        self.voipChannel?.invokeMethod("remoteLog", arguments: logMsg)
      }
      print("[NATIVE-CALLKIT] showCallkitIncoming invoked (returned to caller; awaiting plugin callback) callId=\(callId)")
    }

    if Thread.isMainThread {
      handleVoipPushOnMain()
    } else {
      DispatchQueue.main.sync(execute: handleVoipPushOnMain)
    }
  }

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
    print("[NATIVE-PUSH] standard APNs received context=didReceive(user-tap-or-bg-delivery) payload=\(String(describing: userInfo))")
    if let conversationId = userInfo["conversation_id"] as? String {
      DispatchQueue.main.async { [weak self] in
        self?.apnsChannel?.invokeMethod("notificationTapped", arguments: conversationId)
      }
    }
    completionHandler()
  }

  @objc func configureAudioForWebRTC() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      print("[AppDelegate] AVAudioSession configured for WebRTC: category=playAndRecord mode=voiceChat")
    } catch {
      print("[AppDelegate] AVAudioSession config error: \(error)")
    }
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
