import Flutter
import UIKit
import ContactsUI

class ContactPickerPlugin: NSObject, CNContactPickerDelegate {
  private var result: FlutterResult?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "pickContact" else {
      result(FlutterMethodNotImplemented)
      return
    }
    self.result = result
    let picker = CNContactPickerViewController()
    picker.delegate = self
    DispatchQueue.main.async { [weak self] in
      var root: UIViewController?
      if #available(iOS 13.0, *) {
        root = UIApplication.shared.connectedScenes
          .compactMap { $0 as? UIWindowScene }
          .flatMap { $0.windows }
          .first(where: { $0.isKeyWindow })?.rootViewController
      }
      root = root ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
        ?? UIApplication.shared.windows.first?.rootViewController
      root?.present(picker, animated: true)
    }
  }

  func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
    picker.dismiss(animated: true) { [weak self] in
      let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
      let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
      let email = contact.emailAddresses.first.map { String($0.value) } ?? ""
      self?.result?(["name": name, "phone": phone, "email": email])
      self?.result = nil
    }
  }

  func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
    picker.dismiss(animated: true) { [weak self] in
      self?.result?(nil)
      self?.result = nil
    }
  }
}
