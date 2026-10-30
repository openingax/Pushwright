# Pushwright

A macOS APNs push tester built for AI coding agents as much as for people.

Pushwright is a successor to [Knuff](https://github.com/knuffapp/knuff). A menu-bar app keeps your signing keys in the Keychain. A `pushwright` command-line tool lets you, a script or an agent such as Claude Code or Codex lint a payload, send it to a device or a booted simulator, and get back structured JSON: the APNs response, a stable error code, the likely cause and the fix.

> **Status: M1 (0.1.0).** Sandbox and simulator sends work. Production sends from the CLI are refused until the approval flow lands in M2. The design and roadmap are in [docs/DESIGN.md](docs/DESIGN.md) (Chinese).

## Requirements

- macOS 15 or later on Apple silicon
- Xcode 16 or later, for `xcrun simctl` and to build from source
- An APNs auth key (`.p8`) or a push certificate (`.p12`) from your Apple Developer account

## Build and install

There are no release builds yet, so build from source:

```bash
git clone https://github.com/<you>/Pushwright.git
cd Pushwright
open App/Pushwright.xcodeproj   # set your own team under Signing & Capabilities, then Run
```

The app runs in the menu bar (bell icon) and has no Dock icon. Choose **Install Command Line Tool** from its menu. This links `~/.local/bin/pushwright` to the CLI inside the app bundle, so add `~/.local/bin` to your `PATH` if it isn't there already.

## Setup

1. Menu bar → **Settings… → Profiles → Add .p8 Key…**. Pick `AuthKey_XXXXXXXXXX.p8`; the Key ID is filled in from the file name. Enter your Team ID and, optionally, the app's bundle ID as the default topic.
   Tick only the environments the key may use. Apple lets you scope a key to sandbox only; that is the safe choice for agents.
2. To use a certificate instead, double-click the `.p12` to import it into the login keychain, then **Add Certificate…**.
3. **Targets → Add Device…** saves a device token under a short alias such as `iphone`. Booted simulators need no entry.
4. Run `pushwright doctor` to check the setup.

## Usage

```bash
pushwright doctor                                      # app running? keys present? simctl ok?
pushwright targets                                     # saved devices and booted simulators
pushwright lint alert.apns --topic com.example.app     # local checks, nothing is sent
pushwright send alert.apns --to iphone                 # to a saved device
pushwright send alert.apns --to booted --topic com.example.app   # to the booted simulator
echo '{"aps":{"alert":"Hi"}}' | pushwright send - --to 5f2c…a91c --topic com.example.app --dry-run
pushwright history --last 5
pushwright explain BadDeviceToken
```

When you leave them out, Pushwright infers the push type from the payload, adds the topic suffix the type needs (`.voip`, `.push-type.liveactivity`, …) and picks the priority. `--dry-run` resolves and lints everything, then prints the equivalent `curl` (device) or `xcrun simctl push` (simulator) command instead of sending.

### For AI agents

Every command takes `--json` and reports through the exit code:

| Code | Meaning |
|-----:|---------|
| 0 | Sent (or dry run / lint passed) |
| 1 | APNs or simctl rejected the push |
| 2 | Lint failed |
| 3 | Reserved: delivery expectation not met (M3) |
| 4 | Needs approval in Pushwright.app (production) |
| 5 | Configuration: app not running, no profile, missing key… |
| 64 | Usage error |

A failed send looks like this (trimmed):

```json
{
  "ok": false,
  "error": {
    "code": "APNS_BAD_DEVICE_TOKEN",
    "message": "APNs rejected the push: 400 BadDeviceToken",
    "status": 400,
    "reason": "BadDeviceToken",
    "cause": "The token is invalid. Most often it belongs to the other environment: development-signed builds register sandbox tokens, TestFlight and App Store builds register production tokens.",
    "fix": "Send to the environment the token came from (--env), or get a fresh token from the matching build.",
    "retryable": false,
    "exitCode": 1
  }
}
```

If the same token was accepted in another environment before, `cause` says so, with the time.

A good loop for an agent: `doctor --json` → `targets --json` → `lint` → `send --dry-run` → `send` → on failure, read `error.fix` (or `explain <reason>`) rather than retrying. `retryable: false` follows Apple's list of reasons not to retry.

## How it works

- **Pushwright.app** is the only process that touches keys. It holds the `.p8` keys in the login keychain, caches JWTs for 40 minutes, keeps one HTTP/2 connection per profile and environment, and appends every send to a history log.
- **The CLI** talks to the app over a Unix socket at `~/Library/Application Support/Pushwright/pushwright.sock` (mode 0600). If the app isn't running, the CLI launches it in the background. Read-only commands (`targets`, `profiles`, `history`, `lint`, `explain`) don't need the app.
- **Simulators** get pushes through `xcrun simctl push`, which supports only alert and background pushes up to 4 KB. A simulator on Apple silicon with Xcode 14 or later can also register a real sandbox token; add that token as a device target to test every push type through APNs.
- History stores only the last 6 characters and a hash of each token.

## Development

```bash
swift build          # PushCore and the CLI library
swift test           # JWT, lint rules, error mapping
xcodebuild -project App/Pushwright.xcodeproj -scheme Pushwright -destination 'generic/platform=macOS' build
```

| Path | What it is |
|------|------------|
| `Sources/PushCore` | APNs client, JWT, lint, error table, simctl, history, socket |
| `Sources/PushwrightCLI` | CLI commands (swift-argument-parser) |
| `App/Pushwright` | Menu-bar app and settings |
| `App/CLI` | CLI entry point, embedded in the app at `Contents/Helpers/pushwright` |
| `Tests/PushCoreTests` | Unit tests |

## Roadmap

- **M2**: production sends with per-target approval (approve once, no prompts for 10 minutes), an MCP server for agents, rate limits.
- **M3**: PushwrightProbe, an iOS SDK that reports tokens and delivery receipts (including from a Notification Service Extension) back to the Mac over the local network.

## License

MIT. See [LICENSE](LICENSE).

---

## 中文简介

Pushwright 是 Knuff 的替代品：一个 macOS 菜单栏 App 加一个 `pushwright` 命令行工具，面向 AI agent 设计。所有命令都支持 `--json`，失败时给出稳定的错误码、原因和修复建议，方便 agent 自己排查。

当前是 M1：支持 sandbox 和模拟器推送；生产环境推送要等 M2 的审批流程，在此之前会被拒绝。设计文档见 [docs/DESIGN.md](docs/DESIGN.md)。
