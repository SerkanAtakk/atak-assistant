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
    /// Son pencere kapatıldığında uygulamanın görünmez biçimde çalışmasını
    /// önler ve ana pencereye her zaman güvenli bir dönüş yolu sunar.
    private var statusItem: NSStatusItem?
    private let environment = AppEnvironment()

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("ATAK başlatılıyor — sürüm \(AppInfo.version)")

        buildMainMenu()

        // `make smoke`: pencereyi kullanıcıya açmadan başlatma sağlığını doğrular.
        if ProcessInfo.processInfo.environment["ATAK_SMOKE"] != nil {
            runSmokeCheck()
            return
        }

        buildStatusItem()
        openMainWindow()

        // Görsel regresyon/dokümantasyon modu: yalnız açıkça istenirse tüm
        // çalışan ekranları izole bir koşuda otomatik yakalar.
        if ProcessInfo.processInfo.environment["ATAK_SHOT_SEQUENCE"] != nil {
            runCaptureSequence()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menü çubuğunda yaşamaya devam eder (spec §44).
        false
    }

    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        openMainWindow()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
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
        // Router ayrı bir ObservableObject: bölüm değişimi RootView'ı tazelerken
        // AppEnvironment'ın durum değişimlerinden bağımsız kalır.
        let root = RootView()
            .environmentObject(environment)
            .environmentObject(environment.router)
            .environmentObject(environment.voice)
            // Onay kapısı ve zamanlayıcı kendi `ObservableObject`'leri;
            // `AppEnvironment` üzerinden okunsalardı değişimleri arayüze
            // yansımazdı (iç içe gözlemlenebilir nesneler yayınlamaz).
            .environmentObject(environment.consentGate)
            .environmentObject(environment.focusTimer)
        let hostingView = NSHostingView(rootView: root)
        // NSHostingView'ın hedef ekranın ideal yüksekliğini pencereye dayatması
        // Ayarlar/Notlar gibi uzun yüzeylerde pencereyi büyütüyordu. İçerik
        // pencerenin mevcut sınırına uyar; kaydırmayı ilgili ekran yönetir.
        hostingView.frame = window.contentLayoutRect
        hostingView.autoresizingMask = [.width, .height]
        hostingView.sizingOptions = []
        window.contentView = hostingView

        let frameName = "ATAKMainWindow"
        let restoredFrame = window.setFrameUsingName(frameName)
        window.setFrameAutosaveName(frameName)
        if !restoredFrame { window.center() }
        window.makeKeyAndOrderFront(nil)

        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menü

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "ATAK")
        addItem(
            to: appMenu,
            title: "ATAK Hakkında",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            target: NSApp
        )
        appMenu.addItem(.separator())
        addItem(
            to: appMenu,
            title: "Ayarlar…",
            action: #selector(showSettings),
            keyEquivalent: ",",
            target: self
        )
        appMenu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Hizmetler")
        let servicesItem = NSMenuItem(title: "Hizmetler", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())
        addItem(
            to: appMenu,
            title: "ATAK'ı Gizle",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h",
            target: NSApp
        )
        addItem(
            to: appMenu,
            title: "Diğerlerini Gizle",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h",
            modifiers: [.command, .option],
            target: NSApp
        )
        addItem(
            to: appMenu,
            title: "Tümünü Göster",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            target: NSApp
        )
        appMenu.addItem(.separator())
        addItem(
            to: appMenu,
            title: "ATAK'tan Çık",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
            target: NSApp
        )
        addSubmenu(appMenu, to: mainMenu)

        let fileMenu = NSMenu(title: "Dosya")
        addItem(
            to: fileMenu,
            title: "Ana Pencereyi Aç",
            action: #selector(showMainWindow),
            keyEquivalent: "n",
            target: self
        )
        fileMenu.addItem(.separator())
        addItem(
            to: fileMenu,
            title: "Pencereyi Kapat",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        addSubmenu(fileMenu, to: mainMenu)

        let editMenu = NSMenu(title: "Düzen")
        editMenu.addItem(withTitle: "Geri Al", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Yinele", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, to: mainMenu)

        let viewMenu = NSMenu(title: "Görünüm")
        let destinations: [(AppSection, String)] = [
            (.chat, "1"),
            (.dashboard, "2"),
            (.tasks, "3"),
            (.projects, "4"),
            (.notes, "5"),
            (.calendar, "6"),
            (.focus, "7"),
            (.memory, "8"),
            (.settings, "9"),
        ]
        for (section, keyEquivalent) in destinations {
            let item = addItem(
                to: viewMenu,
                title: section.title,
                action: #selector(showSection(_:)),
                keyEquivalent: keyEquivalent,
                target: self
            )
            item.representedObject = section.rawValue
        }
        viewMenu.addItem(.separator())
        addItem(
            to: viewMenu,
            title: "Kenar Çubuğunu Göster/Gizle",
            action: #selector(toggleSidebar),
            keyEquivalent: "s",
            modifiers: [.command, .control],
            target: self
        )
        addItem(
            to: viewMenu,
            title: "Tam Ekrana Geç",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f",
            modifiers: [.command, .control]
        )
        addSubmenu(viewMenu, to: mainMenu)

        // Yalnız ATAK_SHOT ayarlıyken görünür: dokümantasyon görüntüleri için.
        if WindowCapture.isEnabled {
            let captureMenu = NSMenu(title: "Yakala")
            addItem(
                to: captureMenu,
                title: "Pencereyi PNG kaydet",
                action: #selector(captureWindow),
                keyEquivalent: "s",
                modifiers: [.command, .shift],
                target: self
            )
            addSubmenu(captureMenu, to: mainMenu)
        }

        let windowMenu = NSMenu(title: "Pencere")
        addItem(
            to: windowMenu,
            title: "Simge Durumuna Küçült",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        addItem(
            to: windowMenu,
            title: "Büyüt",
            action: #selector(NSWindow.performZoom(_:))
        )
        windowMenu.addItem(.separator())
        addItem(
            to: windowMenu,
            title: "ATAK'ı Aç",
            action: #selector(showMainWindow),
            keyEquivalent: "0",
            target: self
        )
        addItem(
            to: windowMenu,
            title: "Tümünü Öne Getir",
            action: #selector(NSApplication.arrangeInFront(_:)),
            target: NSApp
        )
        addSubmenu(windowMenu, to: mainMenu)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Yardım")
        addItem(
            to: helpMenu,
            title: "ATAK Yardım",
            action: #selector(showHelp),
            keyEquivalent: "?",
            target: self
        )
        addSubmenu(helpMenu, to: mainMenu)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func addItem(
        to menu: NSMenu,
        title: String,
        action: Selector?,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : modifiers
        item.target = target
        menu.addItem(item)
        return item
    }

    private func addSubmenu(_ submenu: NSMenu, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        mainMenu.addItem(item)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "brain.head.profile",
                accessibilityDescription: "ATAK menüsü"
            )
            image?.isTemplate = true
            button.image = image
            button.title = image == nil ? "A" : ""
            button.toolTip = "ATAK Kişisel Asistan"
        }

        let menu = NSMenu(title: "ATAK")
        let versionItem = NSMenuItem(
            title: "ATAK \(AppInfo.version)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())
        addItem(
            to: menu,
            title: "ATAK'ı Aç",
            action: #selector(showMainWindow),
            target: self
        )
        addItem(
            to: menu,
            title: "Ayarlar…",
            action: #selector(showSettings),
            target: self
        )
        menu.addItem(.separator())
        addItem(
            to: menu,
            title: "ATAK'tan Çık",
            action: #selector(NSApplication.terminate(_:)),
            target: NSApp
        )

        item.menu = menu
        statusItem = item
    }

    @objc private func showMainWindow() { openMainWindow() }

    @objc private func toggleSidebar() {
        environment.router.toggleSidebar()
    }

    @objc private func showSection(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let section = AppSection(rawValue: rawValue)
        else { return }

        openMainWindow()
        environment.router.select(section)
    }

    /// Açık ekranın adıyla PNG kaydeder (ATAK_SHOT modunda).
    @objc private func captureWindow() {
        guard let window = mainWindow else { return }
        do {
            let url = try WindowCapture.capture(window, name: environment.router.section.rawValue)
            Log.app.info("✓ \(url.lastPathComponent, privacy: .public)")
        } catch {
            Log.app.error("Yakalama başarısız: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runCaptureSequence() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            mainWindow?.setContentSize(NSSize(width: 1180, height: 760))
            mainWindow?.center()
            await environment.bootstrap()
            try? await Task.sleep(for: .milliseconds(500))

            for section in [
                AppSection.chat, .dashboard, .tasks, .projects, .notes,
                .calendar, .focus, .memory, .settings,
            ] {
                environment.router.select(section)
                try? await Task.sleep(for: .milliseconds(450))
                guard let window = mainWindow else { return }
                do {
                    try WindowCapture.capture(window, name: section.rawValue)
                } catch {
                    Log.app.error("Otomatik yakalama başarısız: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    @objc private func showSettings() {
        openMainWindow()
        environment.router.select(.settings)
    }

    @objc private func showHelp() {
        openMainWindow()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "ATAK Yardım"
        alert.informativeText = """
        Bölümler arasında ⌘1–⌘9 ile geçebilir, ana pencereyi ⌘N veya ⌘0 ile yeniden açabilirsin.

        ATAK pencere kapalıyken menü çubuğundaki simgeden çalışmaya devam eder.
        """
        alert.addButton(withTitle: "Tamam")

        if let mainWindow {
            alert.beginSheetModal(for: mainWindow)
        }
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
    public static let version = "0.3.1"
    public static let bundleIdentifier = "com.serkanatak.atak"
}
