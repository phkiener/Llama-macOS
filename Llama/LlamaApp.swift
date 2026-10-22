import AppKit
import Sentry
import SwiftUI
import os.log

@main
struct LlamaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    // Empty scene, as we are a menu bar app
    Settings {
      EmptyView()
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings...") {
          SettingsWindowController.shared.showSettings()
        }
        .keyboardShortcut(",")
      }
    }
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  private let logger = Logger(subsystem: Logging.subsystem, category: "AppDelegate")
  private var menuController: MenuController?
  private var networkExposureGuard: NetworkExposureGuard?

  // Deeplink (llama://) plumbing.
  // Cold-launch URL events arrive before `applicationDidFinishLaunching`, so we have
  // to register the Apple-event handler in `applicationWillFinishLaunching`. The app's
  // menu/ModelManager/alert infra isn't ready yet at that point, so the handler just
  // enqueues — the queue drains once full setup completes.
  private var pendingURLs: [URL] = []
  private var didBootstrap = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  @MainActor
  @objc func handleGetURLEvent(
    _ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor
  ) {
    guard
      let str = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let url = URL(string: str)
    else { return }

    if didBootstrap {
      DeeplinkHandler.shared.handle(url: url)
    } else {
      pendingURLs.append(url)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Carry pre-rename (LlamaBarn) settings and staging files into the new
    // (Llama) identity. Must run before anything reads settings or scans the
    // cache below (ModelManager, the server, the menu).
    RenameMigration.runIfNeeded()

    // Drop a commented template at ~/.config/llama/models.user.ini so the
    // override file is discoverable. Must run before the first cache scan
    // regenerates models.ini below.
    UserModelOverrides.seedTemplateIfNeeded()

    // Enable visual debugging if LB_DEBUG_UI is set
    NSView.swizzleDebugBehavior()

    // Initialize Sentry for error reporting (release builds only)
    #if !DEBUG
      SentrySDK.start { options in
        options.dsn =
          "https://9a490c1c8715f73a0db5f65890165602@o509420.ingest.us.sentry.io/4510221602914304"
        options.debug = false
        options.releaseName = AppInfo.shortVersion
        options.environment = AppInfo.shortVersion == "0.0.0" ? "internal" : "production"

        // Disable Sentry's auto-instrumented HTTP client error capture. ModelManager
        // already captures Hugging Face failures manually with richer context
        // (modelId, url), and the auto-instrumentation fires repeatedly per logical
        // failure (e.g. range request retries) creating large amounts of duplicate
        // noise. We have no other external HTTP endpoints worth auto-capturing.
        options.enableCaptureFailedRequests = false

        // Filter out non-actionable network errors globally so they don't use up quota
        options.beforeSend = { event in
          if let error = event.error as NSError? {
            let ignoredCodes = [
              NSURLErrorCancelled,
              NSURLErrorNotConnectedToInternet,
              NSURLErrorNetworkConnectionLost,
            ]
            if error.domain == NSURLErrorDomain && ignoredCodes.contains(error.code) {
              return nil  // Drop this event
            }
          }
          return event
        }
      }
    #endif

    logger.info("Llama starting up")

    // Configure app as menu bar only (removes from Dock)
    NSApp.setActivationPolicy(.accessory)

    // Opt into launch-at-login by default on first launch (one-time; respects a
    // later opt-out in Settings).
    LaunchAtLogin.enableOnFirstLaunch()

    // Scan the model cache and write models.ini, before anything reads either.
    // Synchronous on purpose: the server reads models.ini once at start, so it
    // has to be current first, and `scanNow()` explains why that ordering can't
    // be arranged with an async scan.
    ModelManager.shared.scanNow()

    // Create the AppKit-based status bar menu (installed models only for now)
    menuController = MenuController()

    // Scope network access to the network it was granted on, so the setting
    // doesn't follow the laptop onto someone else's wifi.
    networkExposureGuard = NetworkExposureGuard()
    networkExposureGuard?.start()

    // Register the global-input hotkey and its capture panel -- a system-wide
    // quick-capture that dispatches a prompt to the web UI.
    GlobalInputController.shared.start()

    // Ensure a usable llama binary exists, then start the server in Router Mode.
    LlamaInstallManager.shared.startServerWhenReady()

    // Drain any llama:// URLs that arrived during cold-launch before the rest
    // of the app was ready.
    didBootstrap = true
    let queued = pendingURLs
    pendingURLs.removeAll()
    for url in queued {
      DeeplinkHandler.shared.handle(url: url)
    }

    logger.info("Llama startup complete")
  }

  func applicationWillTerminate(_ notification: Notification) {
    logger.info("Llama shutting down")

    // Gracefully stop the llama-server process when app quits
    LlamaServer.shared.stop()
  }
}
