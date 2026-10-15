# Grok Usage

**English** | **[简体中文](README.zh-CN.md)**

A lightweight macOS menu bar app that shows your **SuperGrok weekly usage**, **Grok Bot weekly usage** (separate pool), and **time until the next reset**.

<p align="center">
  <img src="https://img.shields.io/badge/version-0.4.0-blue" />
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" />
  <img src="https://img.shields.io/badge/license-MIT-orange" />
</p>

> **Unofficial.** Uses the same local login as the Grok Build CLI and a billing metadata API. xAI may change either at any time.

## Features

- **Menu bar icon** — SF Symbol only; hover for a short usage summary
- **Popover details** — SuperGrok progress, product split (Build / Chat / Api …), extra credits, plus separate Grok Bot weekly meter
- **Browser sign-in** — SuperGrok via xAI device login; Bot via Cursor PKCE (optional local Grok Bot fallback)
- **Background refresh** — about every 20 minutes while awake; sleep pauses requests
- **Threshold alerts** — notify once per period at 20 / 40 / 60 / 80 / 90 / 95 / 98% (SuperGrok and Bot independently)
- **Launch at login**
- **Auto token refresh** — renews OIDC / Bot tokens when possible (usually no daily re-login)
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
- An xAI / Grok account (sign in from the app’s **Sign in with browser** button — Grok Build CLI is optional)
- Optional: [Grok Build](https://x.ai/build) CLI login also works (`~/.grok/auth.json` is shared)
- Optional for Bot meter: **Sign in to Bot with browser** (Cursor PKCE; tokens in this app’s Keychain), or a local [Grok Bot](https://grok.com/bot) login as fallback

## How to Use

1. Open **Grok Usage** — the status appears in the menu bar.
2. Click for usage details, product breakdown, and actions.
3. Enable **Launch at Login** if you want it at startup.
4. Allow notifications for threshold alerts.

## Privacy

| Action | Detail |
|--------|--------|
| Read | `~/.grok/auth.json` (shared with Grok Build); optional local Grok Bot secrets as Bot fallback |
| Write | May update tokens in `auth.json`; Bot browser login stores Cursor tokens in this app’s Keychain |
| Network | `auth.x.ai` (SuperGrok), `cli-chat-proxy.grok.com` (SuperGrok), `cursor.com` / `api2.cursor.sh` (Bot login + usage) |
| Not sent | Your code, chats, or project files |

No model calls — only billing metadata.

## Troubleshooting

| Issue | Try |
|-------|-----|
| Missing SuperGrok auth | Use **Sign in with browser**, or run `grok` / `grok login` once |
| Missing Bot meter | Use **Sign in to Bot with browser**, or open Grok Bot once |
| Token refresh fails | Sign in again from the app (or run `grok` once for SuperGrok) |
| No notifications | System Settings → Notifications → Grok Usage |
| Launch at login fails | Use the copy in `/Applications`; allow under Login Items |
| Language picker grayed out | Use a build from `bash build.sh` (includes `en` / `zh-Hans` localizations) |

## Stack

- Swift / SwiftUI + AppKit `NSStatusItem` / `NSPopover` (PowerTop-style)
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
