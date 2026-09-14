# Grok Usage

**English** | **[简体中文](README.zh-CN.md)**

A lightweight macOS menu bar app that shows your **SuperGrok weekly usage**, **Grok Bot weekly usage** (separate pool), and **time until the next reset**.

<p align="center">
  <img src="https://img.shields.io/badge/version-0.2.9-blue" />
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" />
  <img src="https://img.shields.io/badge/license-MIT-orange" />
</p>

> **Unofficial.** Uses the same local login as the Grok Build CLI and a billing metadata API. xAI may change either at any time.

## Features

- **Menu bar readout** — e.g. `Grok 46% · Bot 34% · 4d5h`
- **Popover details** — SuperGrok progress, product split (Build / Chat / Api …), extra credits, plus separate Grok Bot weekly meter
- **Background refresh** — about every 20 minutes while awake; sleep pauses requests
- **Threshold alerts** — notify once per period at 20 / 40 / 60 / 80 / 90 / 95 / 98% (SuperGrok and Bot independently)
- **Launch at login**
- **Auto token refresh** — renews OIDC access tokens via `refresh_token` (usually no daily re-login)
- **Language** — follows macOS language (English / Simplified Chinese), including per-app language in System Settings

## Screenshot

<p align="center">
  <img src="screenshot/popover-en.png" alt="Grok Usage menu panel" width="320" />
</p>

## Installation

### Download (Recommended)

Download the latest `GrokUsage.zip` from [Releases](https://github.com/kDolphin/grok-usage/releases):

1. Unzip
2. Drag `Grok Usage.app` into `/Applications`
3. First launch: right-click → **Open** (unsigned / ad-hoc signed)

### Build from Source

```bash
git clone https://github.com/kDolphin/grok-usage.git
cd grok-usage
bash build.sh
open "build/Grok Usage.app"
```

Install:

```bash
cp -R "build/Grok Usage.app" /Applications/
```

## Requirements

- macOS 13 or later
- [Grok Build](https://x.ai/build) installed and signed in at least once (`~/.grok/auth.json`)
- Optional: [Grok Bot](https://grok.com/bot) signed in once (for the separate Bot weekly meter)

```bash
grok login   # only if you have never signed in
```

## How to Use

1. Open **Grok Usage** — the status appears in the menu bar.
2. Click for usage details, product breakdown, and actions.
3. Enable **Launch at Login** if you want it at startup.
4. Allow notifications for threshold alerts.

## Privacy

| Action | Detail |
|--------|--------|
| Read | `~/.grok/auth.json` (shared with Grok Build); Grok Bot local secrets + Keychain (Bot meter only) |
| Write | May update tokens in `auth.json` on refresh |
| Network | `auth.x.ai` (token refresh), `cli-chat-proxy.grok.com` (SuperGrok), `api2.cursor.sh` (Grok Bot) |
| Not sent | Your code, chats, or project files |

No model calls — only billing metadata.

## Troubleshooting

| Issue | Try |
|-------|-----|
| Missing auth | Run `grok` or `grok login` once |
| Token refresh fails | Run `grok` once |
| No notifications | System Settings → Notifications → Grok Usage |
| Launch at login fails | Use the copy in `/Applications`; allow under Login Items |
| Language picker grayed out | Use a build from `bash build.sh` (includes `en` / `zh-Hans` localizations) |

## Stack

- Swift / SwiftUI `MenuBarExtra`
- No third-party dependencies

## Project layout

```text
GrokUsage/                 # App target (sources + localizations + icon)
  *.swift
  Info.plist
  en.lproj/  zh-Hans.lproj/
  Resources/AppIcon.icns
build.sh                   # → build/Grok Usage.app + GrokUsage.zip
screenshot/                # README images
```

## License

[MIT](LICENSE)
