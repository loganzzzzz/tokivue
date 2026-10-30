import Foundation

public enum CodexQuotaError: Error, LocalizedError, Equatable {
    case executableNotFound
    case executableNotRunnable(String)
    case launchFailed(String)
    case requestTimedOut
    case connectionClosed
    case processExited(Int32)
    case rpcError(code: Int?, message: String)
    case invalidResponse(String)
    case noRateLimits

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未找到 Codex 程序，请在菜单中手动选择。"
        case let .executableNotRunnable(path):
            return "Codex 程序不可执行：\(path)"
        case let .launchFailed(message):
            return "无法启动 Codex：\(message)"
        case .requestTimedOut:
            return "读取额度超时，请稍后重试。"
        case .connectionClosed:
            return "Codex 数据连接已关闭。"
        case let .processExited(status):
            return "Codex 数据服务已退出（状态 \(status)）。"
        case let .rpcError(_, message):
            return "Codex 返回错误：\(message)"
        case let .invalidResponse(message):
            return "无法解析 Codex 额度：\(message)"
        case .noRateLimits:
            return "Codex 没有返回可显示的套餐额度；请确认已使用 ChatGPT 账号登录。"
        }
    }
}

public enum QuotaResponseParser {
    public static func parse(data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CodexQuotaError.invalidResponse("JSON 格式无效")
        }
        guard let dictionary = object as? [String: Any] else {
            throw CodexQuotaError.invalidResponse("响应不是对象")
        }
        return try parse(jsonObject: dictionary, fetchedAt: fetchedAt)
    }

    public static func parse(
        jsonObject object: [String: Any],
        fetchedAt: Date = Date()
    ) throws -> QuotaSnapshot {
        if let error = object["error"] as? [String: Any] {
            let code = number(error["code"])?.intValue
            let message = (error["message"] as? String) ?? "未知错误"
            throw CodexQuotaError.rpcError(code: code, message: message)
        }

        guard let result = object["result"] as? [String: Any] else {
            throw CodexQuotaError.invalidResponse("缺少 result")
        }

        var buckets: [QuotaBucket] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            for (fallbackID, rawValue) in byID {
                guard let rawBucket = rawValue as? [String: Any],
                      let bucket = parseBucket(rawBucket, fallbackID: fallbackID)
                else {
                    continue
                }
                buckets.append(bucket)
            }
        }

        if !buckets.contains(where: { $0.id == "codex" }),
           let rawBucket = result["rateLimits"] as? [String: Any],
           let bucket = parseBucket(rawBucket, fallbackID: "codex") {
            buckets.append(bucket)
        }

        guard !buckets.isEmpty else {
            throw CodexQuotaError.noRateLimits
        }

        buckets.sort { lhs, rhs in
            if lhs.id == "codex", rhs.id != "codex" { return true }
            if rhs.id == "codex", lhs.id != "codex" { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        let resetCredits = (result["rateLimitResetCredits"] as? [String: Any])
            .flatMap { number($0["availableCount"])?.intValue }

        return QuotaSnapshot(
            fetchedAt: fetchedAt,
            buckets: buckets,
            resetCreditsAvailable: resetCredits
        )
    }

    private static func parseBucket(
        _ raw: [String: Any],
        fallbackID: String
    ) -> QuotaBucket? {
        let id = nonEmptyString(raw["limitId"]) ?? fallbackID
        var windows: [QuotaWindow] = []

        if let primary = raw["primary"] as? [String: Any],
           let window = parseWindow(primary, kind: .primary) {
            windows.append(window)
        }
        if let secondary = raw["secondary"] as? [String: Any],
           let window = parseWindow(secondary, kind: .secondary) {
            windows.append(window)
        }
        windows.sort { lhs, rhs in
            switch (lhs.durationMinutes, rhs.durationMinutes) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return false
            }
        }

        let credits: CreditBalance?
        if let rawCredits = raw["credits"] as? [String: Any] {
            credits = CreditBalance(
                hasCredits: rawCredits["hasCredits"] as? Bool,
                unlimited: rawCredits["unlimited"] as? Bool,
                balance: stringValue(rawCredits["balance"])
            )
        } else {
            credits = nil
        }

        let individualLimit = (raw["individualLimit"] as? [String: Any])
            .flatMap(parseIndividualLimit)
        let reachedType = nonEmptyString(raw["rateLimitReachedType"])
        let spendControlReached = raw["spendControlReached"] as? Bool

        guard !windows.isEmpty
                || individualLimit != nil
                || credits != nil
                || reachedType != nil
                || spendControlReached != nil
        else {
            return nil
        }

        return QuotaBucket(
            id: id,
            name: nonEmptyString(raw["limitName"]),
            windows: windows,
            planType: nonEmptyString(raw["planType"]),
            credits: credits,
            individualLimit: individualLimit,
            rateLimitReachedType: reachedType,
            spendControlReached: spendControlReached
        )
    }

    private static func parseIndividualLimit(_ raw: [String: Any]) -> SpendControlLimit? {
        guard let remainingPercent = number(raw["remainingPercent"])?.doubleValue else {
            return nil
        }
        let resetsAt = number(raw["resetsAt"])
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        return SpendControlLimit(
            limit: stringValue(raw["limit"]),
            used: stringValue(raw["used"]),
            remainingPercent: remainingPercent,
            resetsAt: resetsAt
        )
    }

    private static func parseWindow(
        _ raw: [String: Any],
        kind: QuotaWindow.Kind
    ) -> QuotaWindow? {
        guard let usedPercent = number(raw["usedPercent"])?.doubleValue else {
            return nil
        }

        let rawDuration = number(raw["windowDurationMins"])?.intValue
        let durationMinutes = rawDuration.flatMap { $0 > 0 ? $0 : nil }

        let resetsAt: Date?
        if let timestamp = number(raw["resetsAt"])?.doubleValue, timestamp > 0 {
            resetsAt = Date(timeIntervalSince1970: timestamp)
        } else {
            resetsAt = nil
        }

        return QuotaWindow(
            kind: kind,
            usedPercent: usedPercent,
            durationMinutes: durationMinutes,
            resetsAt: resetsAt
        )
    }

    private static func number(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let string = value as? String, let value = Double(string) {
            return NSNumber(value: value)
        }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
