import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  private var workspaceWakeObserver: NSObjectProtocol?

  override func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    observeWorkspaceWake()

    if ProcessInfo.processInfo.arguments.contains("--background") {
      DispatchQueue.main.async { [weak self] in
        (self?.mainFlutterWindow as? MainFlutterWindow)?.hideToBackground()
      }
    } else {
      DispatchQueue.main.async { [weak self] in
        (self?.mainFlutterWindow as? MainFlutterWindow)?.showApplicationWindow()
      }
    }

    UNUserNotificationCenter.current().delegate = self
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag, let window = currentMainFlutterWindow {
      window.showApplicationWindow()
      window.requestTodayPapers()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    if #available(macOS 11.0, *) {
      return [.banner, .sound, .list]
    }
    return [.alert, .sound]
  }

  private func observeWorkspaceWake() {
    workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { _ in }
  }

  private var currentMainFlutterWindow: MainFlutterWindow? {
    mainFlutterWindow as? MainFlutterWindow
  }
}
