import AppKit

/// Pencerenin kendi içeriğini PNG olarak diske yazar.
///
/// Ekran yakalama (`screencapture`, ScreenCaptureKit) macOS'ta Ekran Kaydı izni
/// ister. Burada ekran yakalanmıyor: uygulama kendi görünüm hiyerarşisini
/// yeniden çiziyor. Bu yüzden hiçbir izin gerekmez ve çıktı da daha temiz —
/// masaüstü, gölge ve imleç görüntüye karışmaz.
///
/// Yalnız `ATAK_SHOT` ortam değişkeni ayarlıyken menüye eklenir; normal
/// kullanımda görünmez.
public enum WindowCapture {

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ATAK_SHOT"] != nil
    }

    /// Görüntülerin yazılacağı klasör (`ATAK_SHOT` bir yol ise orası).
    public static var outputDirectory: URL {
        let raw = ProcessInfo.processInfo.environment["ATAK_SHOT"] ?? ""
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Desktop/atak-shots")
    }

    @MainActor
    @discardableResult
    public static func capture(_ window: NSWindow, name: String) throws -> URL {
        guard let view = window.contentView else {
            throw ATAKError.unsupported("Pencerenin içeriği yok.")
        }

        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            throw ATAKError.unsupported("Pencere boyutu geçersiz.")
        }

        guard let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw ATAKError.unsupported("Çizim tamponu oluşturulamadı.")
        }
        view.cacheDisplay(in: bounds, to: representation)

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ATAKError.unsupported("PNG üretilemedi.")
        }

        let directory = outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: "\(name).png")
        try data.write(to: url)

        Log.app.info("Ekran görüntüsü yazıldı: \(url.path, privacy: .public)")
        return url
    }
}
