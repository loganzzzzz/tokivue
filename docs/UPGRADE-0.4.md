# Tokivue 0.4：自动价格、模型周榜和 Fast 估值

这次升级涉及云端接收端、Mac 界面和各设备采集器。先升级云端，再升级采集器；原有数据、设备身份和上传密钥保留。

## 1. 更新现有 Apps Script 项目

不要新建表格，不要重新运行 `setup()`，也不要改已有 Script Properties。

- 将 `collector/google-apps-script/Code.gs` 更新到现有项目的 `Code.gs`。
- 新建脚本文件 `AutoPricing.gs`，复制仓库中同名文件。
- 更新 `appsscript.json`。新增 `script.external_request` 和 `script.scriptapp` 两个 OAuth scope，分别用于读取官方价格和管理定时触发器。
- 若使用提供的 `tokivue-cloud-0.4.zip` 合并发布包，只替换包内的 `Code.gs` 和 `appsscript.json`；不要再单独添加 `AutoPricing.gs`，避免重复声明。

先在编辑器手动运行 `enableTokivueAutomation()`，按 Google 提示完成一次授权。它会创建“模型周榜”、立即检查价格，并为当前 Google 用户建立每 6 小时一次的触发器。仅需一名维护者启用，不要在多个 Google 账号下重复建立触发器。网络暂时失败时触发器会保留，后续仍会重试。

随后在“部署 → 管理部署”中编辑当前 Web 应用，选择新版本并部署，保留原部署地址与访问设置。定时价格更新运行保存后的项目代码；Mac 的周榜和新采集器的档位确认还需要这个 Web 应用新版本。完成后先手动刷新 Mac 看板，确认能进入周榜，再升级采集器。

## 2. 更新 Mac 与 Windows

Mac：按 README 的构建安装步骤安装 Tokivue 0.4.0。只升级界面时，旧接收端仍可显示原来的概要，但周榜会提示需要更新接收端。

采集器：云端部署完成后，在 Mac 运行 `python3 collector/install_macos.py`；Windows 使用新版 collector 目录运行 `01-install.cmd`。保留原配置；不要复制其他设备的完整配置或数据库。

采集器首次运行会在本机数据库持久保存档位统计起点，只对该时刻之后的新事件记录档位。不补录历史 Fast，不重新排队已采集记录；迟到的旧日志也不会增加历史加速费用。重扫仅用于恢复上下文，旧事件 ID 和 Token 数不变。接收端在 `EventTiers` 保存档位，`TokenEvents` 保持原有列结构。旧采集器仍可上传，但这些记录缺少档位时按 Standard 暂估。

## 3. 自动价格规则

- 固定从 `https://developers.openai.com/api/docs/pricing.md` 获取公开价格，无需 API key，不发送账号、密钥或用量。
- 只解析明确标记的主模型 **Standard / Fast、短上下文、30 分钟缓存写入**表。其他表型、长上下文、Batch/Flex、区域附加费及 12 小时缓存保留暂不自动计价。
- `Prices` 保存 Standard；`FastPrices` 保存 Fast。支持直接 A:G 数据表，也支持现有 J:P 参数区加 B2:G2 查找公式的布局。新模型会加入参数区，说明文字下移、查找范围自动扩大。
- 首次只接管“价格与官网一致且来源为官网”的已有行；不同的已有价格按自定义保留。随后只自动更新仍等于上次托管值的行。手动改价或改来源后，该模型会被跳过；若希望恢复托管，把完整价格及来源恢复为官网当前值，再运行检查。
- Luna 家族和自动审核继续排除美元估值；独立生图的假设和金额不由此任务更新。
- 官网缺失模型不会删除本地旧价格。HTTP、解析或表型校验错误会记录并停止本轮更新；不会把未知价格设为零。Sheets 写入不是跨表事务，写入阶段异常可能留下已完成的部分，重试会保留这些已写入值并继续处理。
- `PriceUpdateLog` 记录检查时间、变更前后价格、跳过的自定义价格和错误。Script Properties 中有 `TOKIVUE_PRICE_LAST_SUCCESS`、`TOKIVUE_PRICE_LAST_ERROR`。
- 手动检查：`autoUpdateModelPrices()`；停用：`disableAutoPricing()`；恢复：`enableAutoPricing()`。

Google 时间触发器按平台调度执行，间隔约 6 小时，不保证精确到分钟。自动改价会重算历史 API 等价金额；核实日期不是按历史日期分段计价的生效日。

## 4. 当前周期模型消耗榜

Mac 弹窗点击“当前周期模型消耗榜”，或在 Sheet 打开“模型周榜”。0.4.1 起使用官方当前周额度窗口：重置时间减去窗口时长为起点，重置时间为终点（不包含终点）。只汇总本周期截至查询时刻的已接入设备去重事件，按总 Tokens 降序排列。周期结束但新快照尚未到达时显示等待同步，不混入上一周期。页面显示北京时间的周期起止和统计截止时间。

显示模型、总 Tokens、占比、输入/输出、Fast/Ultrafast Tokens、估值及加速额外估值。Luna、自动审核参与 Tokens 排名，金额标记“已排除”。生图没有实际模型 Token 数据，继续单独统计。离线时榜单带缓存提示；没有新请求时，表格会在下一次采集、看板刷新或自动价格检查时重算，周期随官方快照切换。

## 5. Fast 额外消耗的口径

采集器读取结构化 `thread_settings_applied.thread_settings.service_tier` 或 `turn_context.service_tier`；`priority`/`fast` 归为 Fast，`default`/`standard` 归为 Standard。档位是日志中已应用的请求设置，不是服务端实际结算证明；不存在档位时不猜测。

- Fast 只使用 `FastPrices` 的独立单价，由官网 Fast 表同步输入、缓存读取、输出和缓存写入价格；不按 Standard 固定倍数推算。缺少模型 Fast 价格时标记待计价。自定义价格仍按手动覆盖规则保留。
- Ultrafast 使用已核实规则：GPT-6.2 Astra/Sol 在 2027-03-01 00:00 美国太平洋时间之前为 Standard 的 3 倍，此后为 6 倍；GPT-6 Astra、GPT-6.1 Sol 为 6 倍。其他模型保持待计价。该规则不会从官网自动更新，后续变化需要维护代码。
- “加速额外估值” = 按档位计算的金额 − 同批 Tokens 按 Standard 计算的金额。它已包含在总估值内，不再重复相加；Tokens 本身也不乘倍率。
- 历史 Fast 不补录，旧记录保持 Standard 暂估；只有升级后新增且能确认档位的事件才计算加速额外金额。无法确认档位的部分继续按 Standard 暂估，榜单以中性文字提示“历史记录按 Standard 估算”，并保留对应 Tokens 数量。

本功能不推算 Fast 对订阅额度的实际扣减倍率，官方已用百分比仍直接读取官方账号接口。

参考：[官方价格](https://developers.openai.com/api/docs/pricing)、[GPT-6.2 Astra](https://developers.openai.com/api/docs/models/gpt-6.2-astra)、[Apps Script 时间触发器](https://developers.google.com/apps-script/guides/triggers/installable)。核实日期：2026-11-18。

## 6. 排查首次初始化

若 Google 提示电子表格服务超时，原有数据和价格会保留，已注册的定时触发器也会保留。服务恢复后可重新运行 `enableAutoPricing()`，不需要再次执行 `setup()`。客户端认证后的看板响应包含 `price_update_status`（是否启用、最近成功时间和错误）；公开 GET 不暴露这些信息。只有最近成功时间存在且 FastPrices 已写入，才表示价格初始化完成。

表格服务超时或官网暂时返回 429/50x 时，同一次检查会自动重试，最多 3 次；格式/价格校验错误不会盲目重试。日志写入失败不会遮住原始错误，失败原因仍保存在脚本属性中。
