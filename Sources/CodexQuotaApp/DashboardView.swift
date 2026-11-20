import AppKit
import SwiftUI
import CodexQuotaCore

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var dashboard: SheetsDashboard?
    @Published var error: String?
    @Published var refreshing = false
    @Published var showsModelRankings = false
    @Published var rankingContentHeight: CGFloat = 240
    @Published var fetchedAt: Date?
    @Published var nextRefreshAt: Date?
    var refresh: () -> Void = {}
    var reconnect: () -> Void = {}
    var openSheet: () -> Void = {}
    var quit: () -> Void = {}
    var navigationChanged: () -> Void = {}
    var layoutChanged: () -> Void = {}

    func updateRankingHeight(_ height: CGFloat) {
        let height = ceil(height)
        guard height > 0, abs(rankingContentHeight - height) > 0.5 else { return }
        rankingContentHeight = height
        layoutChanged()
    }

    func showOverview() {
        guard showsModelRankings else { return }
        showsModelRankings = false
        navigationChanged()
    }

    func showRankings() {
        guard !showsModelRankings else { return }
        showsModelRankings = true
        navigationChanged()
    }
}

private struct ControlCenterMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct RankingContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardViewModel
    private let blue = Color(red: 0.08, green: 0.43, blue: 0.96)
    private let ink = Color(red: 0.13, green: 0.15, blue: 0.19)
    private let muted = Color(red: 0.43, green: 0.46, blue: 0.51)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if model.showsModelRankings { rankingCard(now: context.date) } else { card(now: context.date) }
        }
        .frame(width: 344)
        .background(ControlCenterMaterial())
        .preferredColorScheme(.light)
    }

    private func card(now: Date) -> some View {
        let data = model.dashboard
        let remaining = data?.remainingPercent(at: now)
        let stale = data?.isStale(at: now) ?? true
        return VStack(spacing: 10) {
            HStack(alignment: .center) {
                Text("Tokivue").font(.system(size: 17, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(model.error != nil || stale ? Color.orange : Color.green).frame(width: 5, height: 5)
                    Text(model.error != nil ? (model.refreshing ? "正在重试" : "等待重试") : stale ? "待更新" : "Google Sheets")
                        .font(.system(size: 10)).foregroundColor(muted)
                }
                Button(action: model.reconnect) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(blue)
                        .frame(width: 27, height: 27)
                }
                .buttonStyle(ControlCenterButtonStyle())
                .accessibilityLabel("手动重连")
                .help("手动重连 Google Sheets")
            }.padding(.horizontal, 3).padding(.bottom, 1)

            VStack(spacing: 12) {
                HStack(spacing: 15) {
                    ZStack {
                        Circle().stroke(blue.opacity(0.12), lineWidth: 7)
                        Circle().trim(from: 0, to: (remaining ?? 0) / 100)
                            .stroke(blue, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "chart.pie.fill").font(.system(size: 26)).foregroundColor(blue)
                    }.frame(width: 66, height: 66).padding(3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(data?.resetDate.map { $0 <= now } == true ? "等待最新额度" : "本周剩余")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(muted)
                        Text(remaining.map { "\(QuotaFormatting.percent($0))%" } ?? "—")
                            .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                Divider().opacity(0.6)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("下次重置").font(.system(size: 11, weight: .medium))
                        Text("北京时间").font(.system(size: 10)).foregroundColor(muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(date(data?.resetDate, format: "MM/dd HH:mm"))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Text(resetCountdown(data?.resetDate, now: now))
                            .font(.system(size: 10)).foregroundColor(muted)
                    }
                }
            }.padding(14).module()

            HStack(spacing: 10) {
                statistic(icon: "chart.bar.fill", title: "今日 Tokens", value: tokens(data?.today_tokens))
                statistic(icon: "ticket.fill", title: "重置卡", value: data?.reset_credits.map { "\($0) 张" } ?? "—")
            }

            if let images = data?.image_stats {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("成功生图", systemImage: "photo").foregroundColor(muted)
                        Spacer()
                        Text("今日 \(images.today_success) · 累计 \(images.total_success) 次")
                    }.font(.system(size: 11, weight: .medium))
                    Text(String(format: "生图输出估值 $%.2f 已计入 · %d 次待计价", images.estimated_output_cost, images.pending_pricing))
                        .font(.system(size: 10)).foregroundColor(blue)
                    Text("假设 Image 2.5 medium · 实际生图 Tokens 未知")
                        .font(.system(size: 9)).foregroundColor(muted)
                }.padding(10).module()
                .help("以实际图片尺寸向上对齐至 16 像素，按官方计算器估算图片输出成本。未含提示词、参考图输入及流式预览；尺寸缺失或无效的记录待计价。估算图片 Tokens 不并入今日 Tokens。")
            }

            VStack(spacing: 11) {
                moneyRow("当前周额度本设备消耗估值", value: data?.currentDeviceWeeklyCost(at: now), unavailable: "暂无估值")
                    .help("按官方当前周额度的重置时间与窗口时长，仅汇总本设备在该窗口内已上传的用量，按各模型单价计算。")
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 4) {
                    moneyRow("当前周额度账号总估值", value: data?.estimatedAccountTotal(at: now), unavailable: "暂不可估")
                    Text("按账号已用比例推算整周额度")
                        .font(.system(size: 9)).foregroundColor(muted)
                }
                .help("本窗口采集估值 ÷ (1 − 剩余百分比)。金额包含假设 Image 2.5 medium 的生图输出估值；采集不完整、生图输入成本未计入、额度百分比取整会影响结果。")
                Divider().opacity(0.6)
                moneyRow("当前设备累计使用估值", value: data?.current_device_cost, unavailable: "暂无估值")
                    .help("当前设备自接入监控以来已上传的累计用量估值，跨周保留。复制的重复日志归首次上传设备。")
            }.padding(14).module()

            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").font(.system(size: 13)).foregroundColor(muted)
                Text("\(data?.devices?.count ?? 0) 台设备已接入").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("采集 \(date(data?.observedDate, format: "HH:mm"))").font(.system(size: 10)).foregroundColor(muted)
            }.padding(.horizontal, 13).padding(.vertical, 11).module()

            if let error = model.error {
                Text(error + (data == nil ? "" : "，当前显示上次成功同步的数据"))
                    .font(.system(size: 10)).foregroundColor(.orange).lineLimit(2).multilineTextAlignment(.center)
            } else if data?.empty == true {
                Text("等待采集器首次上传").font(.system(size: 10)).foregroundColor(muted)
            }

            Button(action: model.showRankings) {
                HStack { Label("当前周期模型消耗榜", systemImage: "chart.bar.xaxis"); Spacer(); Image(systemName: "chevron.right") }
                    .font(.system(size: 11, weight: .medium)).padding(11)
            }.buttonStyle(ControlCenterButtonStyle())

            HStack(spacing: 8) {
                Button(action: model.refresh) {
                    Label(model.refreshing ? "刷新中…" : "刷新看板", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(ControlCenterButtonStyle()).disabled(model.refreshing)
                Button(action: model.openSheet) {
                    Label("打开表格", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(ControlCenterButtonStyle())
                Button(action: model.quit) {
                    Image(systemName: "power").font(.system(size: 12)).frame(width: 34, height: 34)
                }.buttonStyle(ControlCenterButtonStyle()).help("退出菜单栏看板")
            }
            VStack(spacing: 3) {
                Text("按模型分别估值 · 非订阅余额")
                    .help("按模型和已记录的加速档位估值；历史记录按 Standard 估算。")
                Text("估值未含 Luna、自动审核；生图仅估输出成本")
                Text(model.refreshing ? "正在同步 Google Sheets" : model.error != nil
                     ? "\(refreshCountdown(now)) 秒后自动重试"
                     : "每分钟刷新 · \(refreshCountdown(now)) 秒后更新")
            }.font(.system(size: 9)).foregroundColor(muted).padding(.top, 1)
        }
        .padding(14)
        .foregroundColor(ink)
    }

    private func rankingCard(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: model.showOverview) {
                    Label("返回总览", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(blue)
                        .padding(.horizontal, 10).frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ControlCenterButtonStyle())
                .accessibilityHint("返回 Tokivue 用量总览，不关闭弹窗")
                Spacer(minLength: 0)
                Text("模型消耗榜").font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(blue).frame(width: 34, height: 34)
                }
                .disabled(model.refreshing).buttonStyle(ControlCenterButtonStyle())
                .accessibilityLabel("刷新模型消耗榜")
            }.fixedSize(horizontal: false, vertical: true)

            if let rankings = model.dashboard?.model_rankings, rankings.isCurrent(at: now) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前周额度周期 · 全部设备")
                        .font(.system(size: 10, weight: .medium)).foregroundColor(muted)
                    Text("\(tokens(rankings.total_tokens)) Tokens")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                    Text("\(date(rankings.startDate, format: "MM/dd HH:mm")) — \(date(rankings.windowEndDate, format: "MM/dd HH:mm")) · 北京时间")
                        .font(.system(size: 9)).foregroundColor(muted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).module()

                if rankings.models.isEmpty {
                    Text("当前周期暂无已采集记录")
                        .font(.system(size: 12)).foregroundColor(muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 20).module()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(rankings.models.enumerated()), id: \.element.id) { index, item in
                                rankingRow(item, index: index)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: RankingContentHeightKey.self, value: geometry.size.height)
                        })
                    }
                    .frame(height: min(model.rankingContentHeight, 340))
                    .onPreferenceChange(RankingContentHeightKey.self) { model.updateRankingHeight($0) }
                }
                HStack {
                    Text("按总 Tokens 排序")
                    Spacer()
                    Text("更新 \(date(rankings.observedDate, format: "MM/dd HH:mm"))")
                }.font(.system(size: 9)).foregroundColor(muted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("等待当前周期排行").font(.system(size: 13, weight: .medium))
                    Text("正在等待有效的周额度重置时间和同步数据，请刷新看板。")
                        .font(.system(size: 11)).foregroundColor(muted)
                    Button("打开 Google Sheets", action: model.openSheet).font(.system(size: 11))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).module()
            }
            if model.error != nil {
                Text("离线缓存：榜单可能不是最新数据")
                    .font(.system(size: 10)).foregroundColor(.orange)
            }
            VStack(spacing: 8) {
                Text("API 等价估值 · 生图次数与图片输出估值单独统计")
                    .font(.system(size: 9)).foregroundColor(muted)
                Button(action: model.showOverview) {
                    Label("返回用量总览", systemImage: "arrow.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(blue)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ControlCenterButtonStyle())
                .accessibilityHint("返回额度、今日 Tokens 和设备估值")
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(14).foregroundColor(ink)
    }

    private func rankingRow(_ item: SheetsDashboard.ModelUsage, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(index + 1)").foregroundColor(blue)
                Text(item.model).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                Text(tokens(item.total_tokens)).monospacedDigit()
            }.font(.system(size: 12, weight: .semibold))
            ProgressView(value: min(1, max(0, item.share))).tint(blue)
            HStack {
                Text(String(format: "占比 %.1f%%", item.share * 100))
                Spacer()
                Text(item.excluded ? "估值已排除" : item.cost.map { String(format: "$%.2f", $0) } ?? "待计价")
            }.font(.system(size: 10)).foregroundColor(muted)
            if item.fast_tokens + item.ultrafast_tokens > 0 {
                Text("Fast \(tokens(item.fast_tokens)) · Ultrafast \(tokens(item.ultrafast_tokens)) Tokens")
                    .font(.system(size: 9)).foregroundColor(muted)
                Text(item.extra_cost.map { String(format: "加速额外估值 $%.2f", $0) } ?? "加速估值待确认")
                    .font(.system(size: 10)).foregroundColor(blue)
            }
            if item.unknown_tier_tokens > 0 {
                Text("历史记录按 Standard 估算 · \(tokens(item.unknown_tier_tokens)) Tokens")
                    .font(.system(size: 9)).foregroundColor(muted)
            }
        }.padding(10).module()
    }

    private func statistic(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 25, height: 25).background(blue).clipShape(Circle())
                Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(muted)
            }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13).module()
    }
    private func moneyRow(_ label: String, value: Double?, unavailable: String = "待配置价格") -> some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(muted)
            Spacer()
            Text(value.map { String(format: "$%.2f", $0) } ?? unavailable)
                .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundColor(blue).monospacedDigit()
        }
    }
    private func tokens(_ count: Int64?) -> String {
        guard let count else { return "—" }
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 10_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return String(count)
    }
    private func date(_ value: Date?, format: String) -> String {
        guard let value else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = format
        return formatter.string(from: value)
    }
    private func resetCountdown(_ value: Date?, now: Date) -> String {
        guard let value else { return "等待额度数据" }
        let minutes = Int(value.timeIntervalSince(now) / 60)
        guard minutes > 0 else { return "等待最新额度" }
        return "\(minutes / 1440)天 \(minutes % 1440 / 60)小时 \(minutes % 60)分钟后"
    }
    private func refreshCountdown(_ now: Date) -> Int {
        if let next = model.nextRefreshAt {
            return max(0, Int(ceil(next.timeIntervalSince(now))))
        }
        guard let fetched = model.fetchedAt else { return 60 }
        return max(0, 60 - Int(now.timeIntervalSince(fetched)))
    }
}

private struct ControlCenterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        return configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .module()
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.blue.opacity(pressed ? 0.16 : 0))
                    .allowsHitTesting(false)
            )
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
    }
}

private extension View {
    func module() -> some View {
        self.background(Color.white.opacity(0.73))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 0.7))
            .shadow(color: Color.black.opacity(0.035), radius: 2, y: 1)
    }
}
