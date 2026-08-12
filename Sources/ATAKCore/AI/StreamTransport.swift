import Foundation

/// Sağlayıcıların paylaştığı HTTP akış açma mantığı.
enum StreamTransport {

    /// Uzun süren akışlar için ayrı oturum: istek zaman aşımı yüksek,
    /// ama bağlantı kurma zaman aşımı kısa (yanlış URL'de hemen hata versin).
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // İlk baytın gelmesi uzun sürebiliyor: yerel modeller (Ollama) ilk
        // istekte GB'larca ağırlığı belleğe yüklüyor, bulut tarafında da
        // düşünen modeller cevaba başlamadan önce uzun süre düşünebiliyor.
        // 30 sn burada sebepsiz zaman aşımı üretiyordu.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func makeRequest(
        url: URL,
        body: JSONValue,
        headers: [String: String]
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try body.encodedData()
        return request
    }

    /// Akışı açar ve HTTP durumunu doğrular.
    ///
    /// Hata durumunda gövde tamamen okunup okunabilir bir mesaja çevrilir —
    /// aksi hâlde kullanıcı yalnızca "bir şeyler ters gitti" görürdü.
    static func open(
        _ request: URLRequest,
        provider: String
    ) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ATAKError.provider("\(provider): beklenmeyen yanıt türü")
        }

        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            throw SSE.describeFailure(status: http.statusCode, body: data, provider: provider)
        }

        return bytes
    }

    /// Basit GET + JSON — model listeleme gibi akış olmayan çağrılar için.
    static func getJSON(
        url: URL,
        headers: [String: String],
        provider: String
    ) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ATAKError.provider("\(provider): beklenmeyen yanıt türü")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SSE.describeFailure(status: http.statusCode, body: data, provider: provider)
        }

        return try JSONValue.decode(data)
    }

    /// Ağ hatalarını kullanıcıya anlamlı gelen mesaja çevirir.
    static func humanize(_ error: Error, provider: String, baseURL: String) -> Error {
        if error is ATAKError { return error }
        if error is CancellationError { return ATAKError.cancelled }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error }

        switch nsError.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            if baseURL.contains("localhost") {
                return ATAKError.provider(
                    "\(provider) çalışmıyor gibi görünüyor.\nOllama uygulamasının açık olduğundan emin ol (\(baseURL))."
                )
            }
            return ATAKError.provider("\(provider) sunucusuna bağlanılamadı (\(baseURL)).")
        case NSURLErrorNotConnectedToInternet:
            return ATAKError.provider("İnternet bağlantısı yok.")
        case NSURLErrorTimedOut:
            return ATAKError.provider("\(provider) zaman aşımına uğradı.")
        case NSURLErrorCancelled:
            return ATAKError.cancelled
        default:
            return ATAKError.provider("\(provider): \(nsError.localizedDescription)")
        }
    }
}
