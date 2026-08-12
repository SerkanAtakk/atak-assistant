import AppKit
import ATAKCore

// Xcode olmadan derlendiği için @main/SwiftUI App yaşam döngüsü yerine
// klasik AppKit giriş noktası kullanılıyor. Swift 6'da üst düzey kod
// zaten @MainActor izolasyonludur.
let application = NSApplication.shared
let delegate = ATAKAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
