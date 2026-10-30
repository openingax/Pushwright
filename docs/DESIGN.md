# Pushwright 设计文档

> 状态：草案 v0.4 · 2026-10-30（M1 已实现，见 §13）
> 已定：名字 Pushwright；开源（MIT）；Agent 发生产推送可选"10 分钟内免确认"；通知扩展（NSE）回执放进 M3。
> APNs 相关细节按 2026-10 的苹果文档核对过，实现时以苹果最新文档为准。

## 1. 背景

- **Knuff 停更了。** 最后一版是 2020-05 的 1.3，仓库 2022-09 之后就没有提交了。它只有 Intel 版，靠 Rosetta 才能跑；README 里只有证书鉴权，不支持 .p8；也没有命令行。
- **推送调试越来越多交给 AI Agent**（Claude Code、Codex 等）。Agent 会写 payload、会读代码，但用现有工具会卡在三处：
  1. **凭证**：.p8 / .p12 不该交给 Agent。
  2. **报错难懂**：`BadDeviceToken` 多半是环境搞反了，`DeviceTokenNotForTopic` 是 bundle id 不对。没有提示，Agent 只能乱试。
  3. **看不到结果**：APNs 返回 200 只说明苹果收下了，不代表设备收到，更不代表点开后跳对了页面。
- **一个真实案例**：某 App 点推送冷启动后没有跳到目标页面，页面排版也乱了。原因是接入 UIScene 后，冷启动时整个会话都没有 key window。整个过程 APNs 都返回 200，Knuff 显示成功，问题出在点击之后的 window 和路由逻辑上。只管发送的工具发现不了这类问题。

## 2. 定位与目标

一句话：**人和 AI Agent 共用的推送测试工具。** 人负责保管凭证、批准生产环境发送；Agent 负责发送、校验、等回执、判断结果。

以 MIT 许可证开源，任何 iOS 开发者都能用。

| 目标 | 内容 |
|---|---|
| G1 发送 | 覆盖 APNs HTTP/2 的常用推送类型，支持 .p8 和 .p12，支持真机和模拟器 |
| G2 校验 | 发送前拦住常见错误；发送后把 APNs 错误翻译成"原因 + 修法" |
| G3 回执 | 通过 App 内的 Debug 组件拿到"收到 → 扩展处理 → 点击 → 跳到哪"的时间线，能自动判定 |
| G4 Agent 接入 | CLI 和 MCP 开箱即用，输出结构化，Agent 不读源码也能用对 |
| G5 安全 | Agent 拿不到密钥；生产环境推送必须有人确认 |
| G6 开源可用 | 别人的 App 不用改架构就能接入 Probe（包括闭源 App）；仓库自带示例 App，能演示完整流程 |

**不做：**
- 推送服务的功能：批量推送、营销推送、用户分群、定时推送。
- 账号、云同步、团队共享。
- 首期不做 Android（FCM、国内厂商通道）。
- 不上 Mac App Store（原因见 §11）。

## 3. 现有方案对比

| 方案 | 能做 | 缺什么 |
|---|---|---|
| Knuff | 证书发送、存成文档、配合 Knuff-Framework 自动拿 token | 停更、只有 Intel 版、无 .p8、无 CLI |
| 苹果 Push Notifications Console（网页） | 发测试推送，开发环境可查投递日志 | 网页操作，Agent 不好用；只能看到"苹果有没有投递"这一层 |
| `xcrun simctl push` | 不要证书就能给模拟器发 | 只支持普通 App 推送（VoIP、Live Activity 等都不支持）；不经过 APNs |
| curl + 手写 JWT | 什么都能发 | 每次都要手写；报错是原始字符串；没有历史，也没有回执 |

Pushwright 在发送层面兼容这些方式：可以导出 curl 命令、兼容 simctl 的 `.apns` 文件、记录 `apns-unique-id` 方便去苹果控制台查投递日志。真正的区别在校验、回执和 Agent 接口。

## 4. 核心概念

| 概念 | 说明 |
|---|---|
| Profile | 一套发送凭证：.p8（Key ID + Team ID + 允许的环境）或 .p12 身份。文件里只存元数据，密钥放在钥匙串。 |
| Target | 一个接收端：真机 token 或模拟器。有别名（如 `iphone`），记录 bundle id、环境和来源（Probe 自动登记 / 手动添加 / 模拟器）。 |
| Payload | APNs 的 JSON 内容。可以是 `.apns` 文件，与 simctl 兼容。 |
| Scenario | 可重复运行的测试场景：目标、payload、变量、是否冷启动、期望的回执。存成文件，跟被测项目的代码一起进 git。 |
| Send | 一次发送：请求、APNs 响应、lint 结果，有唯一的 `sendId`。 |
| Trace ID | Pushwright 注入 payload 的追踪 id，用来把回执对应到某一次发送。 |
| Receipt | Probe 从 App 里报回来的事件：收到、扩展处理、点击、冷启动、路由等。 |
| Probe | 集成进被测 App 和它的通知扩展的小组件（只进 Debug 包），负责上报 token 和回执。 |

## 5. 总体架构

```
              ┌────────── Pushwright.app（常驻，可以只显示菜单栏图标）───────┐
 Agent ─CLI──▶│ 本地 socket ──▶ 引擎 PushCore ──▶ APNs（HTTP/2）           │──▶ 真机
 Agent ─MCP──▶│                     │          └─▶ xcrun simctl push       │──▶ 模拟器
 人   ─GUI──▶│ 钥匙串（密钥）· 审批 · 历史（JSONL）· Bonjour 监听 ◀─────────│◀── Probe 回执
              └────────────────────────────────────────────────────────────┘
```

**关键决定：App 是唯一的引擎进程，CLI 只是一个薄客户端。**

- Probe 回执需要一个长期在线的进程来接收。CLI 用完就退出，接不住回执。
- 密钥、审批、历史都只放在 App 这一个地方，不会出现 CLI 和 App 各存一份的情况。
- CLI 发现 App 没在运行时，会在后台把它拉起来（`open -g`），最多等 5 秒 socket 就绪。
- 只有要用到密钥的请求（`send`、`ping`）走 socket。`targets`、`profiles`、`history`、`lint`、`explain` 直接读文件或在 CLI 里算，App 没开也能用。
- socket 每个连接只处理一个请求：客户端写完请求后关闭写端，App 回完结果后关闭连接（以 EOF 分帧）。
- 内部只有一套 API：**MCP 工具的定义就是内部 API**。CLI 子命令和 GUI 按钮最终都转成同样的请求。

| 组件 | 形态 | 职责 |
|---|---|---|
| PushCore | Swift 库（macOS） | APNs 客户端、JWT、simctl、lint、错误解释、场景执行、存储。不依赖 UI，方便单测 |
| Pushwright.app | SwiftUI App | 运行引擎；菜单栏；凭证、目标、审批、历史界面；本地 socket；Bonjour 监听 |
| `pushwright` | 命令行，放在 App 包的 `Contents/Helpers/`（不能放 `Contents/MacOS/`：文件系统默认不区分大小写，会和主程序 `Pushwright` 重名） | CLI 子命令，外加 `pushwright mcp`（stdio 方式的 MCP 服务） |
| PushwrightProbe | Swift 库（iOS，Debug 用，主 App 和通知扩展共用） | 上报 token 和回执，接收"退出 App"等控制指令 |

## 6. 发送

### 6.1 连接与鉴权

- 服务器 `api.sandbox.push.apple.com` / `api.push.apple.com`，端口 443（备选 2197）。HTTP/2 + TLS 1.2 以上，请求是 `POST /3/device/<token>`。
- 用 URLSession，它原生支持 HTTP/2 和连接复用。**每个（Profile, 环境）组合用单独的 session**，因为同一条连接上换 key 会被拒（`UnrelatedKeyIdInToken`）。
- **.p8**：JWT 头部是 `{"alg":"ES256","kid":<KeyID>}`，载荷是 `{"iss":<TeamID>,"iat":<秒>}`。用 CryptoKit 的 `P256.Signing` 签名，它的 `rawRepresentation` 正好就是 JWT 要的 r‖s 格式。生成后缓存，每 40 分钟刷新一次。苹果的规则是：20 分钟内不能重复刷新，超过 60 分钟必须刷新。
- **只限一个环境的 key**：苹果现在支持只能用于 Sandbox 或只能用于 Production 的 key，环境不对会报 `BadEnvironmentKeyIdInToken`。**建议给 Agent 用的 Profile 绑定一把只限 Sandbox 的 key**。这样即使 Pushwright 自身有漏洞，也发不出生产推送。Profile 里记录这把 key 能用的环境，发送前先检查。
- **.p12**：导入时读取证书里的 topic 扩展（OID `1.2.840.113635.100.6.3.6`），自动列出能用的 topic（包括 `.voip` 等），并按证书类型判断能发哪些环境。发送时在 URLSession 的客户端证书挑战里提供 `SecIdentity`。注意证书只支持部分推送类型，比如 `location` 只能用 token 鉴权。

### 6.2 Header

| Header | 处理方式 |
|---|---|
| `apns-push-type` | Pushwright 强制带上。默认从 payload 推断：有 alert / sound / badge 就是 `alert`，只有 `content-available` 就是 `background` |
| `apns-topic` | 默认是 Profile/Target 的 bundle id 加上推送类型对应的后缀（见 6.3） |
| `apns-priority` | 默认 alert 为 10，background 为 5；也可以设成 1 |
| `apns-expiration` | 默认 0，只投递一次、不存储，测试时最符合直觉 |
| `apns-collapse-id` | 可选，不超过 64 字节 |
| `apns-id` | Pushwright 生成 UUID，同时记进这次发送的记录 |

响应里记录：`:status`、`apns-id`、`apns-unique-id`、错误 JSON 里的 `reason`，以及 410 时的 `timestamp`。`apns-unique-id` 只有开发环境才有，可以拿去苹果 Push Notifications Console 查投递日志，界面上提供一键跳转。

### 6.3 推送类型与 topic 后缀

| push-type | topic | 备注 |
|---|---|---|
| `alert` | `<bundle>` | |
| `background` | `<bundle>` | 必须用 priority 5，用 10 会报错 |
| `voip` | `<bundle>.voip` | payload 上限 5KB |
| `liveactivity` | `<bundle>.push-type.liveactivity` | 见 6.4 |
| `widgets` | `<bundle>.push-type.widgets` | |
| `controls` | `<bundle>.push-type.controls` | |
| `location` | `<bundle>.location-query` | 只支持 token 鉴权 |
| `pushtotalk` | `<bundle>.voip-ptt` | |
| `fileprovider` | `<bundle>.pushkit.fileprovider` | |
| `complication` | `<bundle>.complication` | |
| `accessory` | `<bundle>.push-type.accessory` | |
| `mdm` | 证书里的 UID | 不支持（不在目标范围内） |

Payload 上限 4096 字节，VoIP 是 5120 字节，不能压缩。

### 6.4 Live Activity

- **更新 / 结束**：用这个 Live Activity 的 push token，`event` 设为 `update` 或 `end`。必须带 `timestamp`（单位是秒），以及和 App 里 `ContentState` 结构一致的 `content-state`。可选 `stale-date`、`dismissal-date`、`relevance-score`、`alert`。priority 用 5 或 10。
- **远程启动**（iOS 17.2+）：用 push-to-start token，`event` 设为 `start`，还要带 `attributes-type` 和 `attributes`。
- **广播频道**（iOS 18+）：要先调用苹果的频道管理接口建频道，放到 M4 之后再做。
- GUI 提供 Live Activity 模板，帮人填 `timestamp`、`event` 这些固定字段（M4）。

### 6.5 模拟器

- **方式 A：`xcrun simctl push <udid> <bundle> <file>`。** 不要证书，也不经过 APNs，但只支持普通 App 推送（VoIP、Live Activity 等都不支持），payload 不超过 4096 字节。
- **方式 B：走真实 APNs。** Apple 芯片 Mac 上，Xcode 14 以后的模拟器可以注册真实的 Sandbox token。这时模拟器就是一个普通 Target，可以测 simctl 不支持的推送类型。Probe 会自动登记这个 token。
- **默认怎么选**：目标是模拟器并且 simctl 支持这种推送类型，就用方式 A，否则用方式 B。没有 token 时直接报错并说明原因。可以用 `--via simctl|apns` 强制指定。

### 6.6 复现

每次发送都可以用 `--print-curl` 输出等价的 curl 命令，方便脱离 Pushwright 复现。里面的 JWT 用占位符代替，因为 JWT 一小时内都有效，等同于凭证。

## 7. 校验

### 7.1 发送前检查（lint）

规则有固定编号，Agent 可以按编号处理。`error` 会阻止发送，`warn` 只提示（加 `--strict` 时也阻止发送）。

| 编号 | 级别 | 规则 |
|---|---|---|
| L01 | error | 不是合法 JSON；顶层不是对象；缺少 `aps` |
| L02 | error | 超过大小上限（4096，VoIP 5120），提示超了多少字节、最大的是哪个字段 |
| L03 | error | push-type 和 topic 后缀对不上 |
| L04 | error | background 推送的 priority 不是 5，或者带了 alert / sound / badge |
| L05 | error | liveactivity 缺 `timestamp`、`event` 或 `content-state`；`start` 缺 `attributes-type` 或 `attributes` |
| L06 | warn | `timestamp` 看起来是毫秒（13 位数字） |
| L07 | warn | 设了 `mutable-content: 1` 但没有 alert，通知扩展不会执行。场景里期望了 `nse.*` 事件时升级为 error |
| L08 | error | `apns-collapse-id` 超过 64 字节；`badge` 不是整数；`interruption-level` 不是 passive / active / time-sensitive / critical 之一 |
| L09 | error | token 不是偶数长度的十六进制串（不假设 token 长度固定） |
| L10 | error | 目标环境和 Target 登记的环境不一致，或 Profile 的 key 不允许发这个环境 |
| L11 | warn | 自定义字段占用了 trace 注入用的 `pushwright` 键 |

### 7.2 错误解释

每个 APNs `reason` 都对应一个固定错误码，附上可能原因、修法和能否重试。常见的几条：

| reason | 最可能的原因 | 建议 |
|---|---|---|
| `BadDeviceToken` | token 环境搞反了：开发签名包的 token 发到了 Production，或者反过来；也可能是 token 抄错了 | 看 Target 登记的环境。如果这个 token 在另一个环境发成功过，直接指出来。**不会自动改发 Production 重试** |
| `DeviceTokenNotForTopic` | topic 和 token 所属 App 的 bundle id 不一致（多 target、多 bundle id 时常见） | 对比 Target 登记的 bundle id |
| `TopicDisallowed` / `BadTopic` | topic 不在这把 key 或这张证书允许的范围内，或者后缀写错了 | 证书：列出证书里的 topic；key：确认是不是这个 topic 的 topic-specific key |
| `BadCertificateEnvironment` | 证书不支持这个环境 | 换环境或换证书 |
| `BadEnvironmentKeyIdInToken` | key 只限某个环境，和目标环境不一致 | 换成对应环境的 Profile |
| `InvalidProviderToken` | Key ID 或 Team ID 填错了，或者 .p8 已经被吊销 | 核对 Profile，运行 `pushwright doctor` |
| `ExpiredProviderToken` | JWT 已经超过 1 小时，通常是 Mac 系统时间不准 | 检查系统时间；Pushwright 会自动重新生成 |
| `TooManyProviderTokenUpdates` | 20 分钟内换了 JWT | 这是 Pushwright 自己的 bug，应该报给开发者 |
| `Unregistered` / `ExpiredToken`（410） | App 被删了，或者 token 已失效 | 重新获取 token；接了 Probe 的话会自动更新 |
| `PayloadTooLarge` | payload 超限 | 同 L02 |
| `TooManyRequests` | 对同一个 token 发得太快 | 等一会再试 |
| 5xx | 苹果服务端问题 | 按苹果建议退避后重试 |

按苹果文档，这几个错误不应该重试：`BadDeviceToken`、`DeviceTokenNotForTopic`、`Forbidden`、`ExpiredToken`、`Unregistered`、`PayloadTooLarge`。Pushwright 不会自动重试它们。

`pushwright explain <reason>` 可以单独查某个错误的解释。

### 7.3 记住每个 token 的环境

- 一个 token 第一次发送成功时，记下它的环境。之后再往另一个环境发，L10 直接拦下来。
- Probe 登记的 token 自带环境信息：Probe 读 App 里 `embedded.mobileprovision` 的 `aps-environment`。没有描述文件（App Store / TestFlight 包）就当作 production，模拟器当作 sandbox。

## 8. 回执：Probe

### 8.1 接入方式

- 一个纯 Swift 的源码库，没有任何依赖，支持 iOS 15 及以上。SPM 和 CocoaPods 都能接。
- 不限制宿主 App 用什么架构、用不用第三方推送 SDK，只要能拿到系统的推送回调就能接。
- **只进 Debug 包**：CocoaPods 项目用 `:configurations => ['Debug']`；SPM 项目由库内部的 `#if DEBUG` 保证 Release 下是空实现（实现时用 §14 的 `nm` 检查确认）。宿主 App 里的调用也都用 `#if DEBUG` 包起来。
- **显式调用，不做方法交换（swizzle）**。主 App 大约加 6 处调用：

```swift
PushwrightProbe.start(appGroup: "group.com.example.app")  // App 启动时；appGroup 只在接 NSE 回执时需要
PushwrightProbe.didRegister(deviceToken: token)           // 推送注册成功
PushwrightProbe.willPresent(notification)                 // 前台收到（UNUserNotificationCenterDelegate）
PushwrightProbe.didReceive(response)                      // 用户点击（UNUserNotificationCenterDelegate）
PushwrightProbe.didReceiveRemote(userInfo)                // 后台推送
PushwrightProbe.mark("routed", ["page": "detail", "id": id])  // App 自己的业务节点
```

通知扩展（Notification Service Extension）里再加 3 处：

```swift
PushwrightProbe.Extension.didReceive(request)   // NotificationService.didReceive 开头
PushwrightProbe.Extension.willDeliver(content)  // 调用 contentHandler 之前
PushwrightProbe.Extension.timeWillExpire()      // serviceExtensionTimeWillExpire
```

### 8.2 事件

| 事件 | 触发点 | 内容 |
|---|---|---|
| `registered` | `didRegister` | token、bundle id、环境、设备名、系统版本、App 版本和构建号 |
| `nse.received` | 扩展 `didReceive` | 扩展开始处理 |
| `nse.delivered` | 扩展 `willDeliver` | 改写后的标题和正文摘要（各取前 40 个字）、附件数量、处理耗时 |
| `nse.timeout` | 扩展 `timeWillExpire` | 扩展超时，系统会显示原始内容 |
| `received` | `willPresent` / `didReceiveRemote` | 标明是前台还是后台 |
| `opened` | `didReceive(response)` | `actionIdentifier`，以及 `coldStart`（是否冷启动） |
| 自定义 | `mark(name, info)` | App 自己定义，例如跳转完成后报 `routed` |

- 每个事件都带上 trace id（从 payload 的 `pushwright.trace` 读取）、事件时间、以及距进程启动的毫秒数。不是 Pushwright 发出的推送没有 trace id，也照样记录。
- **冷启动的判定**：App 第一次进入前台之前就收到了点击，就算冷启动。UIScene 下冷启动时的回调顺序和旧的 AppDelegate 模式不同，实现时要在真机上实测确认这个顺序。

### 8.3 Trace 注入

发送时在 payload 顶层加上 `"pushwright": {"trace": "<8 位 id>"}`，大约 35 字节，计入大小检查。用 `--no-trace` 可以关掉；场景里如果要等回执，就必须打开。

### 8.4 通信

- **Mac 端**：App 用 Network.framework 的 `NWListener` 发布 Bonjour 服务 `_pushwright._tcp`。macOS 15 以后会弹本地网络权限。
- **iOS 主 App**：Probe 用 `NWBrowser` 找到 Mac，建立 TCP 连接，每行发送一条 JSON（NDJSON）。宿主 App 的 Debug `Info.plist` 要在 `NSBonjourServices` 里加上 `_pushwright._tcp`，并且要有 `NSLocalNetworkUsageDescription`。
- **通知扩展**：扩展是独立进程，最多运行约 30 秒，内存限制也很紧，所以扩展里的 Probe 只用 Foundation 和 Network，不缓存大对象。
  - 主 App 的 Probe 把 Mac 的地址、端口和配对令牌写进 App Group，扩展读出来直接连 Mac，不做 Bonjour 搜索。
  - 2 秒内连不上，就把事件写进 App Group，主 App 下次连上 Mac 时补发。补发的事件仍用扩展里记录的时间。
  - 所以要接 NSE 回执，App 和扩展必须共用一个 App Group。扩展里能不能直接连局域网，要在真机上实测确认。
- **模拟器**：和 Mac 是同一台机器，直接连 `127.0.0.1`，不走 Bonjour。
- **断线**：最近 200 条事件存在 UserDefaults 里（接了 NSE 时存 App Group），重连后补发。这样 App 闪退或网络切换时，冷启动的事件也不会丢。

### 8.5 配对与安全

- **首次连接**：Probe 发送 `hello`（设备名、bundle id、Probe 版本）。Mac 弹窗提示"设备 X 上的 App Y 请求配对"，人点允许后，Mac 下发配对令牌。Probe 把令牌存进钥匙串，之后每次连接都带上。模拟器走回环地址，自动允许。
- **没配对的连接不能登记 Target**。否则局域网里任何设备都能塞进来一个"自己的设备"，绕过生产环境的限制（见 §10）。
- **已知局限**：首期在局域网里明文传输，内容只有 token 和事件，没有密钥。先这样简化，需要时再改用 Network.framework 的 TLS-PSK，用配对令牌当 PSK。

### 8.6 控制指令（Mac → App）

- `terminate`：让 App 自己退出，用来制造冷启动。真机上这比用 `devicectl` 简单，不用去查 pid。模拟器上优先用 `simctl terminate`。App 没连上时，提示人手动上划杀掉。

### 8.7 判定

`expect` 是一个按顺序排列的事件列表。每一项可以带 `match`（对事件字段做全等匹配）和 `within`（超时秒数）。

- 全部满足就算通过。
- 任何一项超时就算失败，同时返回已经收到的事件，方便看出卡在哪一步。比如收到了 `opened` 却一直没有 `routed`，说明问题出在点击之后的路由，§1 里的案例就是这类 bug。

## 9. Agent 接口

### 9.1 设计原则

1. **输出结构化**：`--json` 的输出结构固定，退出码和错误码也固定。
2. **默认值就是对的**：push-type、topic、priority 都能自动推断，Agent 只给 payload 和目标就能发对。
3. **错误里带修法**：Agent 不需要去查文档。
4. **上下文里没有秘密**：凭证用 Profile 名称，目标用别名，token 只显示后 6 位。
5. **工具少而粗**：MCP 只提供 6 个工具，不把每个 header 做成一个工具。
6. **能自我说明**：`--help` 里带示例；`pushwright schema` 输出 payload 和场景文件的 JSON Schema。

### 9.2 CLI

```
pushwright send <payload.apns|-> --to <alias|token> [--profile P] [--env sandbox|production]
                [--type T] [--topic T] [--priority 10|5|1] [--expiration N] [--collapse-id ID]
                [--var k=v ...] [--no-trace] [--via simctl|apns]
                [--expect EVENT[:k=v,...]] [--within SEC] [--dry-run] [--print-curl] [--json]
pushwright lint <payload> [--type T] [--json]
pushwright run <scenario.json> [--to alias] [--var k=v ...] [--json]
pushwright wait <traceId> --expect EVENT [--within SEC] [--json]
pushwright targets [--json]         # 真机（Probe 登记或手动添加）+ 已启动的模拟器
pushwright profiles [--json]        # 只有元数据，不含密钥
pushwright history [--last N] [--trace ID] [--json]
pushwright explain <reason>
pushwright schema payload|scenario
pushwright doctor                   # 检查 App、socket、钥匙串、Xcode/simctl、本地网络权限
pushwright mcp                      # 以 stdio 方式运行 MCP 服务
```

| 退出码 | 含义 |
|---|---|
| 0 | 成功；带 `--expect` 时表示期望全部满足 |
| 1 | APNs 拒绝，或 simctl 失败 |
| 2 | 被 lint 拦下 |
| 3 | 期望没有满足（超时或不匹配） |
| 4 | 需要人工审批，但被拒绝或超时 |
| 5 | 配置问题：找不到 Profile 或 Target，或 App 没就绪 |
| 64 | 命令用法错误 |

`send --json` 成功时的输出：

```json
{
  "ok": true,
  "sendId": "s_20261030_153012_a1b2",
  "traceId": "t7f3a9c2",
  "target": {"alias": "iphone", "env": "sandbox", "bundleId": "com.example.app", "token": "…a91c3f"},
  "request": {"via": "apns", "pushType": "alert", "topic": "com.example.app", "priority": 10, "bytes": 312},
  "apns": {"status": 200, "apnsId": "…", "uniqueId": "…"},
  "lint": [],
  "receipts": [
    {"event": "opened", "atMs": 6120, "coldStart": true},
    {"event": "routed", "atMs": 7480, "info": {"page": "detail", "id": "42"}}
  ],
  "expect": {"met": true}
}
```

失败时的输出：

```json
{
  "ok": false,
  "error": {
    "code": "APNS_BAD_DEVICE_TOKEN",
    "apns": {"status": 400, "reason": "BadDeviceToken"},
    "cause": "这个 token 10-30 14:02 在 sandbox 发送成功过，本次发往 production",
    "fix": "改用 --env sandbox；要测 production 请用 TestFlight 包重新获取 token",
    "retryable": false
  }
}
```

### 9.3 MCP

`pushwright mcp` 以 stdio 方式运行，把请求转给 App。

| 工具 | 输入 | 输出 |
|---|---|---|
| `list_targets` | 无 | 目标列表：别名、平台、环境、bundle id、是否在线 |
| `lint_payload` | payload，可选 pushType | lint 结果 |
| `send_push` | to、payload；可选 profile、env、pushType、headers、vars、expect、within | 和 `send --json` 相同 |
| `wait_receipt` | traceId、expect、within | 回执和判定结果 |
| `run_scenario` | path；可选 to、vars | 同上，外加每条期望各自的结果 |
| `get_history` | 可选 last、traceId | 历史记录 |

- 资源：`pushwright://schema/payload`、`pushwright://schema/scenario`、`pushwright://docs/cheatsheet`（各推送类型的最小可用 payload，见附录 A）。
- 需要人在真机上点通知时，`send_push` 会一直等到 `within` 超时。工具描述里写明这一点，让 Agent 提示用户去操作设备。
- 实现：MCP 要用到的部分很少（initialize、tools/list、tools/call、resources/list、resources/read），先手写 stdio JSON-RPC。以后需要进度通知之类的能力，再换成官方 Swift SDK。

### 9.4 接入 Agent

- App 设置页的"接入 Agent"：
  - 一键安装 CLI 软链到 `~/.local/bin/pushwright`；
  - 一键执行 `claude mcp add pushwright -- /Applications/Pushwright.app/Contents/Helpers/pushwright mcp`（用绝对路径，避免 PATH 问题）；
  - 给出 Codex 等其他 Agent 的配置片段，方便复制。
- 随 App 附一份 `SKILL.md`（什么时候用、常见流程、错误怎么处理），可以安装到 `~/.claude/skills/pushwright/`。

### 9.5 场景文件

场景文件放在被测项目里，比如 `<项目>/pushes/`，跟代码一起进 git。Agent 改了推送处理逻辑后，补一个场景跑一遍，相当于给推送写测试用例。

```json
{
  "name": "冷启动点推送跳转详情页",
  "to": "iphone",
  "coldStart": true,
  "payload": "cold-start-detail.apns",
  "vars": {"id": "42"},
  "expect": [
    {"event": "opened", "match": {"coldStart": true}, "within": 60, "hint": "请点击通知横幅"},
    {"event": "routed", "match": {"page": "detail", "id": "{{id}}"}, "within": 15}
  ]
}
```

- `payload` 可以写 `.apns` 文件路径（这样文件仍然能直接拖进模拟器），也可以直接内联一个对象。
- `{{name}}` 变量在 payload 和 expect 里都会被替换，`--var` 的值优先。
- 运行流程固定：（可选）杀掉 App → 发送 → 按顺序等待期望事件。先这样简化，真需要多步编排时再加 steps。

## 10. 安全

| 风险 | 措施 |
|---|---|
| Agent 拿到密钥 | 密钥只存在钥匙串里，访问权限只给 Pushwright 签名过的 App。CLI 不读钥匙串，只通过 socket 请 App 代为发送。其他进程（包括 `security` 命令）要么读不到，要么会弹系统授权框 |
| Agent 的生产推送发到真实用户手机上 | ① 给 Agent 用的 Profile 绑定只限 Sandbox 的 key；② 来自 CLI/MCP 的 production 请求一律在 App 里弹窗审批，见下方说明；③ production 只能发给 Probe 配对登记过、或人在 GUI 里手动添加的 Target，不接受 Agent 直接给的 token |
| 刷屏 | 每个 Target 每分钟最多 30 条（先用固定上限，不做成配置项） |
| JWT 泄露 | 输出、日志和 `--print-curl` 里的 JWT 一律用占位符 |
| token 泄露 | 输出和日志里只显示后 6 位；完整 token 只能人在 GUI 里查看 |
| 局域网里伪造回执或伪造设备 | Probe 配对令牌（§8.5） |
| 需要紧急停止 | 菜单栏的"暂停 Agent 访问"：socket 拒绝所有请求 |
| 其他系统用户访问 socket | socket 文件放在当前用户目录，权限 0600 |

**生产推送审批弹窗**有三个选项：允许一次、10 分钟内都允许、拒绝。

- "10 分钟内都允许"按 Target 计时：只对这一个 Target 免确认，换 Target 要重新确认。
- 免确认期间，菜单栏显示倒计时，可以随时撤销；每条发送照常记入历史。
- 等待审批时 CLI 会阻塞，超过 2 分钟没人处理按拒绝算（退出码 4）。

说明：同一个用户下的任何进程都能连上 socket，这正是 Agent 能用它的前提。所以真正的防线是"密钥不出 App"和"生产推送需要人审批"，而不是 socket 本身。

## 11. 技术选型

| 项 | 选择 | 理由 |
|---|---|---|
| 语言 / UI | Swift 6 + SwiftUI | |
| 最低系统 | macOS 15，只出 arm64 | 开源要照顾更多用户；macOS 26 是最后一个支持 Intel 的版本，项目的出发点就是摆脱 x86，所以不为 Intel 测试和出包 |
| Probe 最低系统 | iOS 15 | 覆盖大部分在维护的 App |
| HTTP/2 | URLSession | 原生支持 HTTP/2 和客户端证书，不需要三方库 |
| JWT | CryptoKit | 原生支持 ES256 |
| 发现 / 通信 | Network.framework | 原生支持 Bonjour 和 TCP |
| CLI 参数解析 | swift-argument-parser | 唯一的三方依赖（苹果官方出品）；它生成的 `--help` 对 Agent 很重要 |
| MCP | 手写 | 用到的协议部分很少 |
| 存储 | JSON / JSONL 文件 | Agent 也能直接 grep；不需要数据库 |
| 许可证 | MIT | Probe 要嵌进闭源 App 里，GPL 会给使用者带来合规问题；Knuff 也是 MIT |
| 分发 | Developer ID 签名 + 公证，用 `scripts/package-dmg.sh` 打 DMG 发到 GitHub Release；Homebrew 先用自建 tap | Mac App Store 的沙盒会挡住调用 `xcrun simctl`、安装 CLI、本地 socket；官方 cask 仓库对项目知名度有要求 |
| 沙盒 | 不开 App Sandbox，开 Hardened Runtime | 理由同"分发" |
| 文档语言 | README 以英文为主，附中文；本设计文档先用中文 | 开源面向国际用户；设计文档有外部贡献者时再翻译 |
| 界面和 CLI 文案 | 英文，暂不做本地化 | 和 APNs 原文的错误名、字段名保持一致，Agent 也更好解析 |

数据存放在 `~/Library/Application Support/Pushwright/`：

| 文件 | 内容 |
|---|---|
| `profiles.json` | Profile 元数据：名称、Team ID、Key ID、允许的环境、bundle id。不含密钥 |
| `targets.json` | Target 列表 |
| `history.jsonl` | 每次发送写一行；回执作为同一 trace 的事件行追加进来。超过 20MB 时轮转一次（先这样简化） |
| `pushwright.sock` | 本地 socket |

## 12. 工程结构

开源后，其他项目要能用 git 地址直接引用 Probe。SPM 要求 `Package.swift` 放在仓库根目录，所以根目录是 Swift 包，App 的 Xcode 工程放在 `App/` 下，引用根目录的本地包。

```
Pushwright/
├── Package.swift            # 产品：PushCore、PushwrightCLI（macOS）；M3 加 PushwrightProbe（iOS）
├── PushwrightProbe.podspec     # 给 CocoaPods 项目用
├── Sources/
│   ├── PushCore/            # 引擎：APNs、JWT、simctl、lint、explain、scenario、存储
│   ├── PushwrightCLI/       # CLI 命令（swift-argument-parser），做成库是为了让 Xcode 工程里的 CLI target 引用
│   └── PushwrightProbe/        # iOS 端 Probe，主 App 和通知扩展共用
├── Tests/
│   └── PushCoreTests/       # JWT、lint、错误映射、场景解析、变量替换
├── App/
│   ├── Pushwright.xcodeproj    # target：Pushwright（App）、pushwright-cli（产物名 pushwright，复制进 App 包的 Contents/Helpers/）
│   ├── Pushwright/             # SwiftUI App
│   └── CLI/                    # CLI 入口（main.swift），命令实现在 Sources/PushwrightCLI
├── Examples/
│   └── ProbeDemo/           # 示例 iOS App：接好 Probe 和通知扩展，带一个可开关的"点击后不跳转"bug
├── scripts/package-dmg.sh
├── dist/                    # 打包输出，不进 git
├── README.md
├── LICENSE                  # MIT
└── docs/DESIGN.md
```

## 13. 里程碑

每个里程碑做完都能单独用。

M1 就带上一个最小的 App 外壳，原因见 §5：密钥和回执监听都需要一个常驻进程。从第一天起就让 CLI 走 App，以后不用维护两条代码路径。

**M1 发送（替代 Knuff）**
- PushCore：APNs（.p8 / .p12）、JWT 缓存、simctl、lint、错误解释、历史记录。
- 最小 App：菜单栏图标 + 设置页（添加 Profile、手动添加 Target）+ 本地 socket。
- CLI：`send`、`lint`、`targets`、`profiles`、`history`、`explain`、`doctor`，支持 `--json` 和退出码。
- 只允许 Sandbox 和模拟器。M2 的审批流程做好之前，production 一律拒绝。
- README（英文为主）和 LICENSE。
- 验收：
  - 用 CLI 给 Sandbox 真机和模拟器各发一条，都成功；
  - 故意发错环境，能拿到 `BadDeviceToken` 和对应的解释；
  - PushCoreTests 覆盖 JWT、全部 lint 规则和错误映射。
- 实现情况（2026-10-30）：以上都已写完并编译通过；真机、模拟器发送和单测还没跑过。和 §9.2 相比的取舍：
  - 没做 `--via`：目标是模拟器就走 simctl，否则走 APNs；
  - `--print-curl` 合并进 `--dry-run`：dry run 会打印等效的 `curl`（真机）或 `xcrun simctl push`（模拟器）命令；
  - `--var`、`--no-trace`、`--expect`、`--within`、`run`、`wait`、`schema` 依赖场景和回执，留到 M2/M3；
  - 频率上限留到 M2，和审批一起做；
  - Profile 和 Target 只能在设置页增删，CLI 只读；
  - 菜单里加了 Install Command Line Tool：把 `~/.local/bin/pushwright` 软链到 App 包里的 CLI。
  - Xcode 工程里文件夹和 target 都避开了只差大小写的名字（`App/CLI`、`pushwright-cli`），原因同 §5 的 `Contents/Helpers`。

**M2 Agent 接入**
- `pushwright mcp`、`SKILL.md`、一键接入 Claude Code。
- 场景文件和 `run` 命令。这时还没有回执，`expect` 只能判断到 APNs 这一层。
- production 审批弹窗（含"10 分钟内都允许"）、频率上限、"暂停 Agent 访问"。
- 第一个公开版本：公证后的 DMG 发到 GitHub Release，自建 Homebrew tap。
- 验收：
  - Claude Code 能通过 MCP 发出推送；
  - production 请求会弹出审批，拒绝后 CLI 退出码为 4；选了"10 分钟内都允许"后，同一 Target 不再弹窗，换 Target 会再弹。

**M3 回执**
- PushwrightProbe（SPM + podspec）、Bonjour 发现、配对、自动登记 Target、trace 注入、事件、`wait`、场景里的 `expect`、`terminate` 指令。
- 通知扩展回执：`nse.received` / `nse.delivered` / `nse.timeout`，以及 App Group 补发。
- 示例 App `Examples/ProbeDemo`。
- 验收：
  - ProbeDemo 打开"点击后不跳转"开关时，"冷启动点推送跳转详情页"场景要判定失败，并且卡在 `routed`；关掉开关后场景通过（通知由人点击）；
  - 发一条 `mutable-content` 推送，能收到 `nse.received` 和 `nse.delivered`；故意让扩展超时，能收到 `nse.timeout`；
  - 再接入一个真实的 CocoaPods 项目跑通一遍，按 §14 检查 Release 包。

**M4 完整界面**
- 带语法高亮和内联 lint 提示的 JSON 编辑器。
- 侧栏：目标、场景、历史。
- 回执时间线、Live Activity 模板、证书 topic 解析、一键跳转苹果控制台查投递日志。

**以后再说**：广播频道管理、FCM 和国内厂商通道、TLS-PSK。

## 14. 接入现有 App

以 CocoaPods 项目为例，SPM 项目类似：

- **Podfile**：`pod 'PushwrightProbe', :git => '<仓库地址>', :configurations => ['Debug']`。本地开发时可以改用 `:path`。
- **Debug 配置的 Info.plist**：`NSBonjourServices` 里加 `_pushwright._tcp`；如果还没有 `NSLocalNetworkUsageDescription`，要补上说明文字。
- **调用点**：注册 token 的地方、UNUserNotificationCenter 的代理方法、路由跳转完成的地方（调 `mark("routed")`）。全部用 `#if DEBUG` 包起来。
- **要接 NSE 回执**：通知扩展 target 也加上 PushwrightProbe（同样只进 Debug），App 和扩展配同一个 App Group，启动时传给 `PushwrightProbe.start(appGroup:)`。
- **回归**：这些改动碰的是 Podfile、Info.plist、AppDelegate / SceneDelegate 和推送回调，都是影响全局的位置。改完要在真机上回归推送相关的流程：前台收到、后台点击、冷启动点击。
- **验收**：Release 包里不能出现 PushwrightProbe 的符号，用 `nm` 检查。

## 15. 待定问题

已定（2026-10-30）：
- 名字：Pushwright，取自自动化测试工具 Playwright，突出"给 Agent 做自动化测试"。最初暂定的 PushLab 和 GitHub 上同领域的 [Juan-Severiano/PushLab](https://github.com/Juan-Severiano/PushLab) 重名（也是 Swift 写的 macOS 推送测试 App），所以改掉。
- 开源，MIT 许可证。
- Agent 发生产推送：弹窗可选"允许一次"或"10 分钟内都允许"（按 Target 计时），见 §10。
- 通知扩展回执放进 M3。

还没定：
1. **签名主体**：开源项目建议用个人开发者账号做 Developer ID 签名和公证。
2. **冷启动判定的时序**：需要在真机上实测确认（UIScene 下回调顺序变过）。
3. **通知扩展能不能直连局域网**：要在真机上实测；连不上的话，扩展事件只能等主 App 补发，实时性会差一些。

## 附录 A：最小可用 payload

alert：
```json
{"aps": {"alert": {"title": "测试", "body": "Hello"}, "sound": "default"}}
```

alert + 通知扩展（会触发 NSE）：
```json
{"aps": {"alert": {"title": "测试", "body": "Hello"}, "mutable-content": 1}}
```

background（priority 5）：
```json
{"aps": {"content-available": 1}}
```

Live Activity 更新（topic 是 `<bundle>.push-type.liveactivity`）：
```json
{"aps": {"timestamp": 1793347200, "event": "update", "content-state": {"progress": 0.5}}}
```

simctl 文件（`.apns`，可以直接拖进模拟器）：
```json
{"Simulator Target Bundle": "com.example.app", "aps": {"alert": "Hello"}}
```
