import Foundation

public struct SheetsDashboard: Codable, Equatable, Sendable {
    public struct ImageStats: Codable, Equatable, Sendable {
        public let today_success: Int
        public let total_success: Int
        public let pending_pricing: Int
        public let estimated_output_cost: Double
        public let estimated_output_tokens: Int64
    }
    public struct Window: Codable, Equatable, Sendable {
        public let used_percent: Double?
        public let duration_minutes: Int?
        public let resets_at: Double?
        public let limit_id: String?
    }
    public struct Device: Codable, Equatable, Sendable {
        public let name: String
        public let observed_at: String
    }
    public let empty: Bool
    public let observed_at: String?
    public let quota: Window?
    public let reset_credits: Int?
    public let today_tokens: Int64?
    public let recorded_tokens: Int64?
    public let since: String?
    public let total_cost: Double?
    public let current_device_id: String?
    public let current_device_cost: Double?
    public let current_device_window_cost: Double?
    public let window_cost: Double?
    public let missing_prices: Int?
    public let devices: [Device]?
    public let image_stats: ImageStats?

    public var observedDate: Date? {
        guard let observed_at else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: observed_at) ?? ISO8601DateFormatter().date(from: observed_at)
    }

    public var resetDate: Date? {
        quota?.resets_at.map { Date(timeIntervalSince1970: $0) }
    }

    public func remainingPercent(at now: Date = Date()) -> Double? {
        guard !empty, quota?.limit_id == "codex", quota?.duration_minutes == 10080,
              let used = quota?.used_percent, used.isFinite,
              let reset = resetDate, reset > now else { return nil }
        return min(100, max(0, 100 - used))
    }

    public func isStale(at now: Date = Date()) -> Bool {
        guard let date = observedDate else { return true }
        return now.timeIntervalSince(date) > 75 * 60
    }

    public func estimatedAccountTotal(at now: Date = Date()) -> Double? {
        // Extrapolate only this quota window, never the all-time collected cost.
        guard remainingPercent(at: now) != nil, !isStale(at: now),
              let used = quota?.used_percent, used > 0, used <= 100,
              let cost = window_cost, cost.isFinite, cost > 0 else { return nil }
        let estimate = cost / (used / 100)
        return estimate.isFinite ? estimate : nil
    }

    public func currentDeviceWeeklyCost(at now: Date = Date()) -> Double? {
        guard !empty, quota?.limit_id == "codex", quota?.duration_minutes == 10080,
              let reset = resetDate, reset > now, reset.addingTimeInterval(-7 * 24 * 3600) <= now,
              let cost = current_device_window_cost, cost.isFinite, cost >= 0 else { return nil }
        return cost
    }
}

public enum SheetsDashboardError: LocalizedError {
    case notConfigured, invalidEndpoint, unauthorized, incompatibleReceiver, invalidResponse, network
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先配置本机用量采集器"
        case .invalidEndpoint: return "接收端地址不是有效的 Google Apps Script 地址"
        case .unauthorized: return "表格连接验证失败，请检查采集器配置"
        case .incompatibleReceiver: return "接收端尚未启用看板摘要"
        case .invalidResponse: return "表格返回的数据格式不正确"
        case .network: return "暂时无法连接 Google Sheets"
        }
    }
}

public final class SheetsDashboardClient: NSObject, URLSessionTaskDelegate {
    public var sheetURL: URL {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["sheet_url"] as? String,
           let url = URL(string: value), url.scheme == "https", url.host == "docs.google.com",
           url.path.hasPrefix("/spreadsheets/d/") { return url }
        return URL(string: "https://docs.google.com/spreadsheets/")!
    }
    private struct Configuration: Decodable {
        let upload_url: String
        let upload_secret: String
        let account_key: String
        let device_id: String
        let device_name: String
    }
    private struct Envelope: Decodable {
        let ok: Bool
        let error: String?
        let ack_ids: [String]?
        let dashboard: SheetsDashboard?
    }
    private struct Cache: Codable {
        let accountKey: String
        let fetchedAt: Date
        let dashboard: SheetsDashboard
    }
    private let directory: URL
    private var session: URLSession!
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-usage-monitor")) {
        self.directory = directory
        super.init()
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 45
        settings.timeoutIntervalForResource = 60
        settings.urlCredentialStorage = nil
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        session = URLSession(configuration: settings, delegate: self, delegateQueue: nil)
    }
    public func stop() { session.invalidateAndCancel() }

    private func configuration() throws -> Configuration {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let config = try? JSONDecoder().decode(Configuration.self, from: data),
              config.upload_secret.count >= 32,
              config.account_key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw SheetsDashboardError.notConfigured
        }
        return config
    }

    public static func validEndpoint(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "script.google.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: "^/macros/s/[A-Za-z0-9_-]+/exec$", options: .regularExpression) != nil else { return nil }
        return url
    }

    public func cached() -> (SheetsDashboard, Date)? {
        guard let config = try? configuration(),
              let data = try? Data(contentsOf: directory.appendingPathComponent("menubar-dashboard.json")),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              config.account_key == cache.accountKey,
              cache.dashboard.current_device_id == nil || cache.dashboard.current_device_id == config.device_id
        else { return nil }
        return (cache.dashboard, cache.fetchedAt)
    }

    public static func parse(_ data: Data) throws -> SheetsDashboard {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw SheetsDashboardError.invalidResponse
        }
        guard envelope.ok else { throw SheetsDashboardError.unauthorized }
        guard envelope.ack_ids == [] else { throw SheetsDashboardError.invalidResponse }
        guard let dashboard = envelope.dashboard else { throw SheetsDashboardError.incompatibleReceiver }
        return dashboard
    }

    public func fetch(completion: @escaping (Result<SheetsDashboard, Error>) -> Void) {
        do {
            let config = try configuration()
            guard let endpoint = Self.validEndpoint(config.upload_url) else { throw SheetsDashboardError.invalidEndpoint }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // An authenticated empty batch reads only the same account's aggregate. No token events are added.
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "version": 1, "secret": config.upload_secret, "account_key": config.account_key,
                "device_id": config.device_id, "device_name": config.device_name,
                "events": [], "snapshots": [],
            ])
            session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                let result: Result<SheetsDashboard, Error>
                do {
                    guard error == nil, let response = response as? HTTPURLResponse,
                          response.statusCode == 200, let data, data.count < 1_000_000 else {
                        throw SheetsDashboardError.network
                    }
                    let dashboard = try Self.parse(data)
                    if let deviceID = dashboard.current_device_id, deviceID != config.device_id {
                        throw SheetsDashboardError.invalidResponse
                    }
                    if let current = try? self.configuration(), current.account_key == config.account_key {
                        let cache = Cache(accountKey: config.account_key, fetchedAt: Date(), dashboard: dashboard)
                        let url = self.directory.appendingPathComponent("menubar-dashboard.json")
                        if let encoded = try? JSONEncoder().encode(cache) {
                            try? encoded.write(to: url, options: .atomic)
                            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                        }
                    }
                    result = .success(dashboard)
                } catch { result = .failure(error) }
                completion(result)
            }.resume()
        } catch { completion(.failure(error)) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host ?? ""
        guard request.url?.scheme == "https",
              host == "script.google.com" || host == "script.googleusercontent.com" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    public static func fetchOnce() throws -> SheetsDashboard {
        let client = SheetsDashboardClient()
        defer { client.stop() }
        let ready = DispatchSemaphore(value: 0)
        var outcome: Result<SheetsDashboard, Error>?
        client.fetch { outcome = $0; ready.signal() }
        guard ready.wait(timeout: .now() + 65) == .success, let outcome else { throw SheetsDashboardError.network }
        return try outcome.get()
    }
}
