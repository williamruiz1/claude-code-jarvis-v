import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Thin facade over Sparkle 2.x. When the Sparkle SPM module is available
/// (resolved at build time), this class wires a real `SPUStandardUpdaterController`
/// and the "Check for Updates…" menu/button hits Sparkle. When it isn't
/// (e.g. SPM dependency failed to resolve, or built in an offline sandbox),
/// it falls back to a no-op + a friendly alert so the app still builds and
/// runs without network-fetched dependencies.
///
/// Appcast URL is read from Info.plist key `SUFeedURL`. Replace with a real
/// URL when you start publishing — see README "Sparkle appcast publishing".
final class SparkleBridge: NSObject {

    static let shared = SparkleBridge()

    /// Read at init from `Info.plist` → `SUFeedURL`. The placeholder we ship
    /// with does NOT host a real appcast — see README for the publishing flow.
    let appcastURLString: String

    /// True if a real Sparkle updater is wired. False if we're in stub mode.
    var isOperational: Bool {
        #if canImport(Sparkle)
        return updaterController != nil
        #else
        return false
        #endif
    }

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    override private init() {
        let bundle = Bundle.main
        self.appcastURLString = (bundle.infoDictionary?["SUFeedURL"] as? String)
            ?? "https://example.invalid/voicemode-menubar/appcast.xml"
        super.init()
        bootstrap()
    }

    private func bootstrap() {
        #if canImport(Sparkle)
        // startingUpdater:true kicks off the periodic background check.
        // userDriverDelegate / updaterDelegate left nil — defaults are fine
        // for our use.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
    }

    /// Wire to a menu item or button via target/action.
    @objc func checkForUpdates(sender: Any?) {
        #if canImport(Sparkle)
        if let controller = updaterController {
            controller.checkForUpdates(sender)
            return
        }
        #endif
        // Fallback: tell the user what's going on so the button isn't silently dead.
        let alert = NSAlert()
        alert.messageText = "Updates not configured"
        alert.informativeText = """
        This build of VoiceMode Monitor was compiled without the Sparkle update framework, \
        or no appcast feed is configured yet.

        See README → "Sparkle appcast publishing" for the steps to wire a real update channel.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
