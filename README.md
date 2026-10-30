# Codex Usage Monitor

本地用量采集器、Google Sheets 汇总接收端和 macOS 原生菜单栏看板。

## 界面预览

以下图片均使用虚构示例数据。macOS 卡片由实际界面组件渲染；Google Sheets 图片为布局示意，不含真实账号、表格链接或用量记录。

### macOS 状态栏弹窗

浅色控制中心风格：周剩余额度、今日 Tokens、生图统计和三项美元估值集中展示；右上角可手动重连。

<p>
  <img src="docs/images/macos-dashboard.png" alt="macOS 正常同步用量卡片，使用虚构示例数据" width="344" />
  <img src="docs/images/macos-offline.png" alt="macOS 离线缓存与自动重试状态，使用虚构示例数据" width="344" />
</p>

左图为正常同步，右图为暂时离线：保留上次结果，并显示重试提示。点击弹窗外部可关闭，窗口也会在 30 秒后自动收起。

### Google Sheets 用量看板

多设备共用一个汇总表；三项估值顺序与菜单栏一致。下方数据表保存去重后的用量事件与额度快照。

<img src="docs/images/sheets-dashboard.png" alt="Google Sheets 浅色用量看板布局示意，使用虚构示例数据" width="500" />

## 功能

- macOS / Windows 定时读取本地 Codex 日志及只读账号额度接口，不启动模型任务。
- 北京时间周一至周五 09:00–18:00 每 10 分钟采集，其余时间每小时；不自动识别法定节假日。睡眠期间不运行。
- 多设备事件去重、失败保留队列、归档会话与可验证的压缩用量采集。
- 周剩余额度、今日 Tokens、本设备周估值、账号周额度总估值、本设备累计估值。
- 成功生图计数，按 GPT Image 2.5 medium 和实际尺寸估算输出成本；不包含图片输入成本，不把估算图片 Tokens 混入实际 Tokens。
- macOS 浅色控制中心式弹窗，60 秒读取 Sheets 汇总、手动重连、30 秒自动收起。

Windows 包提供后台采集，不包含 macOS 菜单栏界面。

## 首次配置

需要 Python 3.9+、已登录的原生 Codex CLI 和 Google 账号。macOS 应用还需要 macOS 13+、Xcode Command Line Tools。

1. 在项目根目录运行 `python3 collector/monitor.py init`。配置保存在 `~/.codex-usage-monitor/config.json`（Windows 对应用户目录）。
2. 在配置中设置 `codex_binary` 为可执行的原生 CLI 路径。Windows 不要填写桌面应用 `Codex.exe` 或目录路径。
3. 运行 `python3 collector/monitor.py run --force`，验证账号并生成 `account_key`。此时未配置上传是正常状态。
4. 创建一个专用空白 Google Sheet，以及独立 Apps Script 项目。复制 `collector/google-apps-script/Code.gs` 和 `appsscript.json`。
5. 在脚本属性中设置 `SPREADSHEET_ID`、`ACCOUNT_KEY`（本机配置中的账号指纹）、`UPLOAD_SECRET`（随机且至少 32 字符；可用 Python `secrets.token_urlsafe(32)` 生成）。这些值只保存于私有配置和脚本属性。
6. 运行 `setup()` 初始化表结构，然后运行 `enableImageGenerationStats()` 创建图片事件表。`setup()` 会重新创建看板布局，仅用于专用表首次部署。
7. 在 `Prices` 表 A:G 的标题下填入各模型价格，列顺序为模型、输入、缓存读取、输出、缓存写入、来源 URL、核实日期。可参考 `collector/pricing-reference.json` 中已标注日期的历史价格；正式使用前核对官方价格。缺价模型会阻止完整金额显示。不要运行针对旧私人表布局的价格迁移函数。
8. 将 Apps Script 部署为 Web 应用，执行身份为自己，访问者为任何人。表格本身保持私有。接口以请求体中的共享密钥与账号指纹鉴权；持有密钥者可以读取汇总，请勿分享密钥。
9. 将部署地址和密钥填入本机配置的 `upload_url`、`upload_secret`，将表格 HTTPS 链接填入 `sheet_url`（macOS“打开表格”按钮使用）。再次运行采集确认上传。
10. 要启用浅色三项估值看板：首次成功上传后，将 `QuotaSnapshots` 中目标设备的 `device_id` 填入“用量看板”K23，运行 `syncLightOverview()`，再运行 `enableImageGenerationStats()`。共享表格固定显示该设备；各 Mac 菜单栏按各自设备显示。

Luna 与自动审核保留 Tokens，但默认排除美元估值。价格为 Standard 短上下文参考值，不含 Fast、区域附加费等。账号总估值为本窗口采集金额除以官方已用比例；已用 0%、数据过期或缺价时不估算。这不是订阅余额。

## macOS 安装

完成私有配置后：

```sh
python3 collector/install_macos.py
chmod +x scripts/*.sh
./scripts/build-app.sh
open "dist/Codex Quota.app"
```

可用 `./scripts/install-chatgpt-autostart.sh` 安装到用户 Applications 并启用 ChatGPT 联动启动。
采集器卸载：`python3 collector/install_macos.py --uninstall`，保留配置及历史数据。

## Windows 安装

复制 `collector` 目录至 Windows，安装标准 Python 后双击 `01-install.cmd`，输入自己的接收端地址和密钥。也可先按上述步骤初始化配置。已有安装会保留设备身份和队列。

- `02-check.cmd`：手动采集、上传并检查。
- `03-uninstall.cmd`：取消当前用户计划任务，保留本地数据。
- 多设备必须独立生成 `device_id`，不要复制整个 config.json 或 usage.sqlite；只复制接收端地址、密钥、账号指纹和需要一致的采集起始日期。

## 验证

```sh
swift run CodexQuotaTests
swift build -c release
(cd collector && python3 -m unittest test_monitor test_windows)
(cd collector && node test_receiver.cjs)
```

Python 与接收端测试使用合成数据，不需要真实 Google 或 Codex 凭据。Windows 任务注册仍需在 Windows 实机验证。

## 数据边界

上传只包含模型、用量时间、Token 数、账号额度、设备标识，以及成功生图事件的尺寸；不上传对话、图片、项目文件或登录令牌。图片日志没有实际模型和质量信息，medium 仅为明确的估算假设。

官方周额度由最新账号快照决定，不把多设备百分比相加。菜单栏每 60 秒刷新的是服务器汇总；不代表采集器每分钟获取额度，因此会有最多一个采集周期的延迟。未接入设备、云端任务、删除的日志及缺少可解析事件的旧版生图可能不在统计内。

本仓库不包含私人部署地址、账号指纹、配置、数据库、实际用量截图或运行日志。部署和使用者自行保管本地 `~/.codex-usage-monitor` 目录。
