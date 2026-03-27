// ios/Runner/SecurityChannel.swift
//
// AXPHONE — Native Security Channel (iOS)
// Registrare in SceneDelegate dopo GeneratedPluginRegistrant.register()
//
// Aggiungere in SceneDelegate.swift:
//   SecurityChannel.register(with: engine)

import Foundation
import UIKit
import Flutter
import Darwin
import MachO
import Network
import CommonCrypto
import CFNetwork

class SecurityChannel {

  static func register(with engine: FlutterEngine) {
    let channel = FlutterMethodChannel(
      name: "com.axphone.app/security",
      binaryMessenger: engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "checkJailbreakRoot":
        result(SecurityChannel.isJailbroken())
      case "checkDebuggerAttached":
        result(SecurityChannel.isDebuggerAttached())
      case "getBinaryHash":
        result(SecurityChannel.binaryHash())
      case "getBinaryHashDetailed":
        let known = call.arguments as? String
        result(SecurityChannel.binaryHashDetailed(known: known))
      case "checkHookFrameworks":
        result(SecurityChannel.checkHookFrameworks())
      case "checkNetworkAnomalies":
        result(SecurityChannel.checkNetworkAnomalies())
      case "checkClipboardHijack":
        result(SecurityChannel.checkClipboardHijack())
      case "checkMediaHijack":
        result(["microphone_used_by": nil, "camera_used_by": nil])
      case "checkOverlayAttack":
        result(false)
      case "checkAccessibilityAbuse":
        result([])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func isJailbroken() -> [String: Any] {
    // Vettore 1: path noti
    let jailbreakPaths = [
      "/Applications/Cydia.app",
      "/Library/MobileSubstrate/MobileSubstrate.dylib",
      "/bin/bash",
      "/usr/sbin/sshd",
      "/etc/apt",
      "/private/var/lib/apt/",
      "/usr/bin/ssh",
      "/private/var/stash",
      "/private/var/mobile/Library/SBSettings/Themes",
      "/Library/MobileSubstrate/DynamicLibraries/Veency.plist",
      "/Library/MobileSubstrate/DynamicLibraries/LiveClock.plist",
      "/System/Library/LaunchDaemons/com.ikey.bbot.plist",
      "/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist",
    ]
    for path in jailbreakPaths {
      if FileManager.default.fileExists(atPath: path) {
        return [
          "detected": true,
          "vector": "filesystem",
          "detail": path,
          "severity": "high",
        ]
      }
    }

    // Vettore 2: sandbox escape
    let testPath = "/private/jailbreak_axphone_test.txt"
    do {
      try "test".write(
        toFile: testPath,
        atomically: true, encoding: .utf8)
      try FileManager.default.removeItem(atPath: testPath)
      return [
        "detected": true,
        "vector": "sandbox_escape",
        "detail": "write succeeded in /private/",
        "severity": "high",
      ]
    } catch {}

    // Vettore 3: Cydia URL scheme
    if let url = URL(string: "cydia://package/com.example.package"),
       UIApplication.shared.canOpenURL(url) {
      return [
        "detected": true,
        "vector": "cydia_url_scheme",
        "detail": "cydia:// URL scheme responded",
        "severity": "high",
      ]
    }

    // Vettore 4: symlink /Applications
    if let result = try? FileManager.default
      .destinationOfSymbolicLink(atPath: "/Applications"),
      !result.isEmpty {
      return [
        "detected": true,
        "vector": "symlink",
        "detail": "/Applications → \(result)",
        "severity": "medium",
      ]
    }

    // Vettore 5: librerie sospette in dyld
    let suspiciousLibs = [
      "MobileSubstrate", "substrate", "cycript",
      "FridaGadget", "frida-gadget", "SSLKillSwitch",
    ]
    for i in 0..<_dyld_image_count() {
      if let name = _dyld_get_image_name(i) {
        let libName = String(cString: name)
        for sus in suspiciousLibs {
          if libName.lowercased().contains(sus.lowercased()) {
            return [
              "detected": true,
              "vector": "dyld_library",
              "detail": libName,
              "severity": "high",
            ]
          }
        }
      }
    }

    return [
      "detected": false,
      "vector": "none",
      "detail": "all \(jailbreakPaths.count) paths clean, sandbox intact",
      "severity": "none",
    ]
  }

  static func isDebuggerAttached() -> [String: Any] {
    var info = kinfo_proc()
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var size = MemoryLayout<kinfo_proc>.stride
    let result = sysctl(&mib, UInt32(mib.count),
      &info, &size, nil, 0)
    guard result == 0 else {
      return [
        "detected": false,
        "vector": "sysctl_error",
        "detail": "sysctl returned \(result)",
        "pid": Int(getpid()),
        "severity": "none",
      ]
    }
    let traced = (info.kp_proc.p_flag & P_TRACED) != 0
    return [
      "detected": traced,
      "vector": traced ? "ptrace_p_traced" : "none",
      "detail": traced
        ? "P_TRACED flag set on PID \(getpid())"
        : "PID \(getpid()) — no debugger flag",
      "pid": Int(getpid()),
      "p_flag": Int(info.kp_proc.p_flag),
      "severity": traced ? "high" : "none",
    ]
  }

  static func binaryHash() -> String {
    guard let execPath = Bundle.main.executablePath,
          let data = FileManager.default.contents(atPath: execPath)
    else { return "unknown" }
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  static func binaryHashDetailed(known: String?) -> [String: Any] {
    guard let execPath = Bundle.main.executablePath,
          let data = FileManager.default.contents(atPath: execPath)
    else {
      return [
        "detected": false,
        "vector": "hash_unavailable",
        "detail": "cannot read executable",
        "currentHash": "unknown",
        "knownHash": known ?? "none",
        "severity": "none",
      ]
    }
    var hash = [UInt8](repeating: 0,
      count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress,
        CC_LONG(data.count), &hash)
    }
    let currentHash = hash.map {
      String(format: "%02x", $0) }.joined()
    let knownHash = known ?? ""
    let tampered = !knownHash.isEmpty
      && currentHash != knownHash
      && knownHash != "unknown"

    return [
      "detected": tampered,
      "vector": tampered ? "binary_hash_mismatch" : "none",
      "detail": tampered
        ? "hash changed: was \(String(knownHash.prefix(16)))... now \(String(currentHash.prefix(16)))..."
        : "hash stable: \(String(currentHash.prefix(16)))...",
      "currentHash": currentHash,
      "knownHash": knownHash.isEmpty ? "not_set" : knownHash,
      "executableSize": data.count,
      "severity": tampered ? "critical" : "none",
    ]
  }

  static func checkHookFrameworks() -> [String: Any] {
    let indicators: [String: [String]] = [
      "frida": ["frida", "FridaGadget", "frida-gadget"],
      "substrate": ["MobileSubstrate", "substrate",
        "SSLKillSwitch"],
      "cycript": ["cycript"],
    ]
    for (framework, names) in indicators {
      for i in 0..<_dyld_image_count() {
        if let name = _dyld_get_image_name(i) {
          let libName = String(cString: name)
          for n in names {
            if libName.lowercased()
              .contains(n.lowercased()) {
              return [
                "detected": true,
                "vector": "dyld_library",
                "framework": framework,
                "detail": libName,
                "severity": "high",
              ]
            }
          }
        }
      }
    }
    if isFridaPortOpen() {
      return [
        "detected": true,
        "vector": "frida_port_27042",
        "framework": "frida",
        "detail": "TCP connect succeeded on 127.0.0.1:27042",
        "severity": "high",
      ]
    }
    return [
      "detected": false,
      "vector": "none",
      "framework": "none",
      "detail": "no hook libraries in dyld, port 27042 closed",
      "severity": "none",
    ]
  }

  static func isFridaPortOpen() -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(27042).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return connected == 0
  }

  static func checkNetworkAnomalies() -> [String: Any] {
    var proxyDetected = false
    var proxyHost = ""
    var proxyPort = ""
    var vpnActive = false
    var vpnInterfaces: [String] = []

    if let proxySettings = CFNetworkCopySystemProxySettings()?
      .takeRetainedValue() as? [String: Any] {
      let httpProxy = proxySettings["HTTPProxy"] as? String
      let httpsProxy = proxySettings["HTTPSProxy"] as? String
      let httpPort = proxySettings["HTTPPort"]
      let httpsPort = proxySettings["HTTPSPort"]
      if let host = httpProxy ?? httpsProxy {
        proxyDetected = true
        proxyHost = host
        proxyPort = "\(httpPort ?? httpsPort ?? 0)"
      }
    }

    if let interfaces = try? FileManager.default
      .contentsOfDirectory(atPath: "/var/run/") {
      vpnInterfaces = interfaces.filter {
        $0.hasPrefix("utun") || $0.hasPrefix("ppp")
      }
      vpnActive = !vpnInterfaces.isEmpty
    }

    let detected = proxyDetected || vpnActive
    var vector = "none"
    var detail = "no anomalies"
    var severity = "none"

    if proxyDetected {
      vector = "http_proxy"
      detail = "proxy \(proxyHost):\(proxyPort)"
      severity = "medium"
    } else if vpnActive {
      vector = "vpn_interface"
      detail = "interfaces: \(vpnInterfaces.joined(separator: ", "))"
      severity = "low"
    }

    return [
      "detected": detected,
      "proxy_detected": proxyDetected,
      "proxy_host": proxyHost,
      "proxy_port": proxyPort,
      "vpn_active": vpnActive,
      "vpn_trusted": false,
      "vpn_interfaces": vpnInterfaces,
      "vector": vector,
      "detail": detail,
      "severity": severity,
    ]
  }

  static func checkClipboardHijack() -> [String: Any] {
    let pb = UIPasteboard.general
    let current = pb.changeCount
    let stored = UserDefaults.standard.integer(forKey: "axphone_clipboard_count")

    let appState: String
    switch UIApplication.shared.applicationState {
    case .active: appState = "active"
    case .inactive: appState = "inactive"
    case .background: appState = "background"
    @unknown default: appState = "unknown"
    }

    var contentType = "empty"
    var preview = ""
    if pb.hasStrings, let s = pb.string {
      contentType = "text"
      preview = String(s.prefix(80))
    } else if pb.hasImages {
      contentType = "image"
    } else if pb.hasURLs {
      contentType = "url"
      if let u = pb.url { preview = String(u.absoluteString.prefix(80)) }
    }

    if stored == 0 {
      UserDefaults.standard.set(current, forKey: "axphone_clipboard_count")
      return [
        "reason": "baseline_init",
        "hijack": false,
        "appState": appState,
        "delta": 0,
        "contentType": contentType,
        "contentPreview": preview,
        "changeCount": current,
      ]
    }
    if current != stored {
      let delta = current - stored
      UserDefaults.standard.set(current, forKey: "axphone_clipboard_count")
      let hijack = UIApplication.shared.applicationState == .background
      return [
        "reason": hijack ? "changed_while_background" : "changed_foreground",
        "hijack": hijack,
        "appState": appState,
        "delta": delta,
        "contentType": contentType,
        "contentPreview": preview,
        "changeCount": current,
      ]
    }
    return [
      "reason": "no_change",
      "hijack": false,
      "appState": appState,
      "delta": 0,
      "contentType": contentType,
      "contentPreview": preview,
      "changeCount": current,
    ]
  }
}
