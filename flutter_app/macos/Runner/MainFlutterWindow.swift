import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var nativeChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)
    configureNativeChannel(for: flutterViewController)

    super.awakeFromNib()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideToBackground()
    return false
  }

  func showApplicationWindow() {
    NSApp.activate(ignoringOtherApps: true)
    // Do NOT call zoom(nil) — on macOS 26 this can enter full-screen mode
    // which hides the menu bar entirely. Instead, size the window to fill
    // the visible screen area (i.e. below the menu bar).
    if let screen = NSScreen.main {
      let visibleFrame = screen.visibleFrame
      setFrame(visibleFrame, display: true, animate: false)
    }
    deminiaturize(nil)
    makeKeyAndOrderFront(nil)
  }

  func hideToBackground() {
    orderOut(nil)
  }

  func requestTodayPapers() {
    nativeChannel?.invokeMethod("showTodayPapers", arguments: nil)
  }

  private func configureNativeChannel(for flutterViewController: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "arxiv_reader/native",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    nativeChannel = channel

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "window_unavailable",
            message: "Main window is not available.",
            details: nil
          )
        )
        return
      }

      switch call.method {
      case "requestNotificationPermission":
        self.requestNotificationPermission(result: result)
      case "showNotification":
        self.showNotification(call: call, result: result)
      case "chooseDirectory":
        self.presentDirectoryPicker(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func requestNotificationPermission(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { granted, error in
      DispatchQueue.main.async {
        if let error {
          result(
            FlutterError(
              code: "notification_permission_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
          return
        }
        result(granted)
      }
    }
  }

  private func showNotification(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Notification arguments were missing.",
          details: nil
        )
      )
      return
    }

    let title = arguments["title"] as? String ?? "ArxivReader AI"
    let body = arguments["body"] as? String ?? ""
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { error in
      DispatchQueue.main.async {
        if let error {
          result(
            FlutterError(
              code: "notification_delivery_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
          return
        }
        result(nil)
      }
    }
  }

  private func presentDirectoryPicker(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let title = arguments?["title"] as? String ?? "Choose folder"
    let initialPath = arguments?["initialPath"] as? String ?? ""

    let panel = NSOpenPanel()
    panel.title = title
    panel.message = "Select a folder."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    panel.directoryURL = resolvedInitialDirectory(from: initialPath)
    NSApp.activate(ignoringOtherApps: true)
    self.makeKeyAndOrderFront(nil)
    let response = panel.runModal()
    guard response == .OK else {
      result(nil)
      return
    }
    result(panel.url?.path)
  }

  private func resolvedInitialDirectory(from initialPath: String) -> URL? {
    guard !initialPath.isEmpty else {
      return defaultDocumentsDirectory()
    }

    let expandedPath = (initialPath as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
      if isDirectory.boolValue {
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
      }
      return URL(fileURLWithPath: expandedPath).deletingLastPathComponent()
    }

    return defaultDocumentsDirectory()
  }

  private func defaultDocumentsDirectory() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
  }
}
