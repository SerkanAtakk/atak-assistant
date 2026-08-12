import AppKit
import SwiftUI

/// ATAK'ın AppKit giriş noktası.
///
/// SwiftUI `App` yaşam döngüsü yerine AppKit kullanılıyor çünkü bu makinede
/// Xcode yok; `@main` + SwiftUI Scene kurulumu SwiftPM çalıştırılabilirinde
/// güvenilir değil. AppKit kabuğu ayrıca menü çubuğu ve global kısayol
/// (Hızlı ATAK) için zaten gerekli olacak.
@MainActor
public final class ATAKAppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindow: NSWindow?
    private let environment = AppEnvironment()

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("ATAK başlatılıyor — sürüm \(AppInfo.version)")

        buildMainMenu()
        openMainWindow()

        // `make smoke`: pencereyi kullanıcıya açmadan başlatma sağlığını doğrular.
        if ProcessInfo.processInfo.environment["ATAK_SMOKE"] != nil {
            runSmokeCheck()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menü çubuğunda yaşamaya devam eder (spec §44).
        false
    }

    // MARK: - Pencere

    private func openMainWindow() {
        if let existing = mainWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ATAK"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        window.setFrameAutosaveName("ATAKMainWindow")
        // Router ayrı bir ObservableObject: bölüm değişimi RootView'ı tazelerken
        // AppEnvironment'ın durum değişimlerinden bağımsız kalır.
        let root = RootView()
            .environmentObject(environment)
            .environmentObject(environment.router)
            .environmentObject(environment.voice)
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)

        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menü

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "ATAK Hakkında", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ayarlar…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "ATAK'ı Gizle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "ATAK'tan Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Düzen")
        editMenu.addItem(withTitle: "Geri Al", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Yinele", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Pencere")
        windowMenu.addItem(withTitle: "Simge Durumuna Küçült", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "ATAK'ı Aç", action: #selector(showMainWindow), keyEquivalent: "0")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showMainWindow() { openMainWindow() }

    @objc private func showSettings() {
        openMainWindow()
        environment.router.select(.settings)
    }

    // MARK: - Smoke

    private func runSmokeCheck() {
        Task { @MainActor in
            let report = await environment.selfCheck()
            for line in report.lines { print(line) }
            print(report.passed ? "SMOKE_OK" : "SMOKE_FAIL")
            NSApp.terminate(nil)
        }
    }
}

public enum AppInfo {
    public static let version = "0.1.0"
    public static let bundleIdentifier = "com.serkanatak.atak"
}
