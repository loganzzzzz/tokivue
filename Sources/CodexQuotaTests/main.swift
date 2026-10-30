import CodexQuotaCore
import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws {
    guard actual == expected else {
        let detail = message.isEmpty ? "expected \(expected), got \(actual)" : message
        throw TestFailure(description: detail)
    }
}

private func expectNil<T>(_ value: T?, _ message: String = "expected nil") throws {
    guard value == nil else { throw TestFailure(description: message) }
}

private func parse(_ json: String) throws -> QuotaSnapshot {
    try QuotaResponseParser.parse(
        data: Data(json.utf8),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private let tests: [(String, () throws -> Void)] = [
    ("表格地址来自本地配置且仅接受 Google Sheets HTTPS", {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SheetsDashboardClient(directory: directory)
        defer { client.stop() }
        try expect(client.sheetURL.absoluteString, "https://docs.google.com/spreadsheets/")
        for (value, expected) in [
            ("https://docs.google.com/spreadsheets/d/example/edit", "https://docs.google.com/spreadsheets/d/example/edit"),
            ("https://example.com/spreadsheets/d/example", "https://docs.google.com/spreadsheets/"),
            ("file:///tmp/private", "https://docs.google.com/spreadsheets/")
        ] {
            try JSONSerialization.data(withJSONObject: ["sheet_url": value]).write(to: directory.appendingPathComponent("config.json"))
            try expect(client.sheetURL.absoluteString, expected)
        }
    }),
    ("本设备周消耗只读独立周金额且重置后不显示旧周", {
        let json = """
        {"ok":true,"ack_ids":[],"dashboard":{"empty":false,"quota":{"used_percent":5,"duration_minutes":10080,"resets_at":2000000000,"limit_id":"codex"},"current_device_window_cost":12.5,"current_device_cost":900,"window_cost":50}}
        """
        let now=Date(timeIntervalSince1970:1999999000)
        let d=try SheetsDashboardClient.parse(Data(json.utf8))
        try expect(d.currentDeviceWeeklyCost(at:now),12.5)
        try expectNil(d.currentDeviceWeeklyCost(at:Date(timeIntervalSince1970:2000000000)))
        try expectNil(d.currentDeviceWeeklyCost(at:Date(timeIntervalSince1970:1900000000)))
        for value in ["0","null","-1"] {
            let changed=try SheetsDashboardClient.parse(Data(json.replacingOccurrences(of:"\"current_device_window_cost\":12.5",with:"\"current_device_window_cost\":\(value)").utf8))
            if value == "0" { try expect(changed.currentDeviceWeeklyCost(at:now),0) }
            else { try expectNil(changed.currentDeviceWeeklyCost(at:now)) }
        }
    }),
    ("当前设备估值独立解析，缓存拒绝其他设备", {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = String(repeating: "a", count: 64)
        let config: [String: Any] = ["upload_url":"https://script.google.com/macros/s/example/exec", "upload_secret":String(repeating:"s",count:32), "account_key":account, "device_id":"device-local", "device_name":"Mac"]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
        let client = SheetsDashboardClient(directory: directory)
        defer { client.stop() }
        for device in ["device-local", "device-other"] {
            let dashboard: [String: Any] = ["empty":false,"total_cost":900,"window_cost":50,"current_device_id":device,"current_device_cost":123.45]
            let envelope: [String: Any] = ["ok":true,"ack_ids":[],"dashboard":dashboard]
            let parsed = try SheetsDashboardClient.parse(JSONSerialization.data(withJSONObject: envelope))
            try expect(parsed.current_device_cost,123.45)
            try expect(parsed.window_cost,50)
            let cache: [String: Any] = ["accountKey":account,"fetchedAt":0,"dashboard":dashboard]
            try JSONSerialization.data(withJSONObject: cache).write(to: directory.appendingPathComponent("menubar-dashboard.json"))
            try expect(client.cached() != nil, device == "device-local")
        }
        let legacy = try SheetsDashboardClient.parse(Data("{\"ok\":true,\"ack_ids\":[],\"dashboard\":{\"empty\":false,\"total_cost\":900}}".utf8))
        try expectNil(legacy.current_device_cost)
    }),
    ("账号总估值使用本窗口金额和原始已用比例", {
        let json = """
        {"ok":true,"ack_ids":[],"dashboard":{"empty":false,"observed_at":"2026-09-09T04:00:00Z","quota":{"used_percent":5,"duration_minutes":10080,"resets_at":2000000000,"limit_id":"codex"},"total_cost":900,"window_cost":50}}
        """
        let d = try SheetsDashboardClient.parse(Data(json.utf8))
        try expect(d.estimatedAccountTotal(at: d.observedDate!),1000)
        let fractional = try SheetsDashboardClient.parse(Data(json.replacingOccurrences(of: "\"used_percent\":5", with: "\"used_percent\":2.5").utf8))
        try expect(fractional.estimatedAccountTotal(at: fractional.observedDate!),2000)
    }),
    ("数据不足或额度失效时不推算账号总估值", {
        let template = """
        {"ok":true,"ack_ids":[],"dashboard":{"empty":false,"observed_at":"2026-09-09T04:00:00Z","quota":{"used_percent":USED,"duration_minutes":10080,"resets_at":2000000000,"limit_id":"codex"},"window_cost":COST}}
        """
        for (used,cost) in [("0","50"),("null","50"),("-1","50"),("101","50"),("5","null"),("5","0"),("5","-1")] {
            let json = template.replacingOccurrences(of:"USED",with:used).replacingOccurrences(of:"COST",with:cost)
            let d = try SheetsDashboardClient.parse(Data(json.utf8))
            try expectNil(d.estimatedAccountTotal(at:d.observedDate!))
        }
        let d = try SheetsDashboardClient.parse(Data(template.replacingOccurrences(of:"USED",with:"100").replacingOccurrences(of:"COST",with:"50").utf8))
        try expect(d.estimatedAccountTotal(at:d.observedDate!),50)
        try expectNil(d.estimatedAccountTotal(at:d.observedDate!.addingTimeInterval(76*60)))
        try expectNil(d.estimatedAccountTotal(at:Date(timeIntervalSince1970:2000000001)))
    }),
    ("Google Sheets 摘要不累加各设备额度，过期后不显示旧额度", {
        let data = Data("""
        {"ok":true,"ack_ids":[],"dashboard":{"empty":false,"observed_at":"2026-09-09T04:00:00.000Z","quota":{"used_percent":5,"duration_minutes":10080,"resets_at":2000000000,"limit_id":"codex"},"today_tokens":12345678,"total_cost":38.93,"window_cost":21.25,"reset_credits":3,"devices":[{"name":"Mac","observed_at":"2026-09-09T04:00:00Z"},{"name":"Windows","observed_at":"2026-09-09T03:50:00Z"}]}}
        """.utf8)
        let d = try SheetsDashboardClient.parse(data)
        try expect(d.remainingPercent(at: Date(timeIntervalSince1970: 1900000000)),95)
        try expectNil(d.remainingPercent(at: Date(timeIntervalSince1970: 2000000001)))
        try expect(d.devices?.count,2)
        try expect(d.total_cost,38.93)
        try expect(d.today_tokens,12345678)
        try expect(d.observedDate != nil,true)
        try expect(d.isStale(at: d.observedDate!.addingTimeInterval(76*60)),true)
    }),
    ("Google Sheets 无价格时保留未知值", {
        let d = try SheetsDashboardClient.parse(Data("{\"ok\":true,\"ack_ids\":[],\"dashboard\":{\"empty\":true}}".utf8))
        try expectNil(d.total_cost)
        try expectNil(d.remainingPercent())
        do {
            _ = try SheetsDashboardClient.parse(Data("{\"ok\":false,\"error\":\"unauthorized\"}".utf8))
            throw TestFailure(description: "unauthorized response was accepted")
        } catch is SheetsDashboardError {}
    }),
    ("上传密钥仅发往指定 Google Apps Script 地址", {
        try expect(SheetsDashboardClient.validEndpoint("https://script.google.com/macros/s/example-1/exec") != nil,true)
        for url in ["http://script.google.com/macros/s/example/exec", "https://script.google.com.evil.test/macros/s/example/exec", "https://script.google.com/macros/s/example/exec?secret=x", "https://user@script.google.com/macros/s/example/exec"] {
            try expectNil(SheetsDashboardClient.validEndpoint(url))
        }
    }),
    ("解析当前仅周额度的响应", {
        let snapshot = try parse("""
        {
          "id": 2,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "primary": {"usedPercent": 15, "windowDurationMins": 10080, "resetsAt": 1786160990}
            },
            "rateLimitsByLimitId": {
              "codex": {
                "limitId": "codex",
                "limitName": null,
                "primary": {"usedPercent": 15, "windowDurationMins": 10080, "resetsAt": 1786160990},
                "secondary": null,
                "planType": "pro",
                "credits": {"hasCredits": false, "unlimited": false, "balance": "0"}
              }
            },
            "rateLimitResetCredits": {"availableCount": 0, "credits": []}
          }
        }
        """)

        try expect(snapshot.buckets.count, 1)
        try expect(snapshot.mainBucket?.id, "codex")
        try expect(snapshot.mainBucket?.planType, "pro")
        try expect(snapshot.mainBucket?.windows.first?.durationMinutes, 10_080)
        try expect(snapshot.statusBarRemainingPercent, 85)
        try expectNil(snapshot.mainBucket?.window(durationMinutes: 300))
        try expect(snapshot.resetCreditsAvailable, 0)
    }),
    ("按窗口时长识别而非 primary/secondary 顺序", {
        let snapshot = try parse("""
        {
          "id": 2,
          "result": {
            "rateLimitsByLimitId": {
              "codex": {
                "limitId": "codex",
                "primary": {"usedPercent": 20.5, "windowDurationMins": 10080, "resetsAt": 2000000000},
                "secondary": {"usedPercent": 70, "windowDurationMins": 300, "resetsAt": 1900000000}
              }
            }
          }
        }
        """)

        try expect(snapshot.mainBucket?.window(durationMinutes: 300)?.remainingPercent, 30)
        try expect(snapshot.mainBucket?.window(durationMinutes: 10_080)?.remainingPercent, 79.5)
        try expect(snapshot.statusBarRemainingPercent, 30)
    }),
    ("解析动态多额度并把 Codex 主额度排在首位", {
        let snapshot = try parse("""
        {
          "id": 2,
          "result": {
            "rateLimitsByLimitId": {
              "model_z": {
                "limitId": "model_z",
                "limitName": "Model Z",
                "primary": {"usedPercent": 1, "windowDurationMins": 60}
              },
              "codex": {
                "limitId": "codex",
                "primary": {"usedPercent": 2, "windowDurationMins": 300}
              }
            }
          }
        }
        """)

        try expect(snapshot.buckets.map(\.id), ["codex", "model_z"])
        try expect(snapshot.buckets[1].displayName, "Model Z")
    }),
    ("兼容旧的单额度字段", {
        let snapshot = try parse("""
        {
          "id": 2,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "primary": {"usedPercent": "40", "windowDurationMins": "300"}
            }
          }
        }
        """)

        try expect(snapshot.buckets.count, 1)
        try expect(snapshot.statusBarRemainingPercent, 60)
    }),
    ("把异常百分比限制在 0 到 100", {
        let overused = try parse("""
        {"result":{"rateLimits":{"primary":{"usedPercent":130,"windowDurationMins":300}}}}
        """)
        try expect(overused.statusBarRemainingPercent, 0)

        let negative = try parse("""
        {"result":{"rateLimits":{"primary":{"usedPercent":-10,"windowDurationMins":300}}}}
        """)
        try expect(negative.statusBarRemainingPercent, 100)
    }),
    ("保留 RPC 错误信息", {
        do {
            _ = try parse("""
            {"id":2,"error":{"code":-32601,"message":"Method not found"}}
            """)
            throw TestFailure(description: "expected parser to throw")
        } catch let error as CodexQuotaError {
            try expect(error, .rpcError(code: -32601, message: "Method not found"))
        }
    }),
    ("拒绝空额度响应", {
        do {
            _ = try parse("""
            {"id":2,"result":{"rateLimits":null,"rateLimitsByLimitId":{}}}
            """)
            throw TestFailure(description: "expected parser to throw")
        } catch let error as CodexQuotaError {
            try expect(error, .noRateLimits)
        }
    }),
    ("格式化窗口时长", {
        try expect(QuotaFormatting.durationLabel(minutes: 300), "5 小时")
        try expect(QuotaFormatting.durationLabel(minutes: 10_080), "7 天")
        try expect(QuotaFormatting.durationLabel(minutes: 2_880), "2 天")
        try expect(QuotaFormatting.durationLabel(minutes: 90), "90 分钟")
    }),
    ("支持只有个人用量上限的账户", {
        let snapshot = try parse("""
        {
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "planType": "enterprise",
              "primary": null,
              "secondary": null,
              "individualLimit": {
                "limit": "1000",
                "used": "580",
                "remainingPercent": 42,
                "resetsAt": 1900000000
              }
            }
          }
        }
        """)
        try expect(snapshot.statusBarRemainingPercent, 42)
        try expect(snapshot.mainBucket?.individualLimit?.used, "580")
        try expect(snapshot.mainBucket?.individualLimit?.limit, "1000")
    }),
    ("保留未返回窗口时长的合法响应", {
        let snapshot = try parse("""
        {"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":null}}}}
        """)
        try expect(snapshot.statusBarRemainingPercent, 75)
        try expectNil(snapshot.mainBucket?.windows.first?.durationMinutes)
    }),
    ("触发服务端限制时主状态显示为零", {
        let snapshot = try parse("""
        {
          "result": {
            "rateLimits": {
              "primary": {"usedPercent": 15, "windowDurationMins": 10080},
              "rateLimitReachedType": "workspace_member_usage_limit_reached"
            }
          }
        }
        """)
        try expect(snapshot.statusBarRemainingPercent, 0)
    }),
    ("主额度缺少百分比时不借用模型专属额度", {
        let snapshot = try parse("""
        {
          "result": {
            "rateLimitsByLimitId": {
              "codex": {
                "limitId": "codex",
                "credits": {"hasCredits": false, "unlimited": false, "balance": "0"}
              },
              "model_only": {
                "limitId": "model_only",
                "primary": {"usedPercent": 10, "windowDurationMins": 10080}
              }
            }
          }
        }
        """)
        try expectNil(snapshot.statusBarRemainingPercent)
    }),
]

var failureCount = 0
for (name, test) in tests {
    do {
        try test()
        print("✓ \(name)")
    } catch {
        failureCount += 1
        print("✗ \(name)：\(error)")
    }
}

if failureCount > 0 {
    print("\n\(failureCount) 项测试失败")
    exit(1)
}

print("\n全部 \(tests.count) 项测试通过")
