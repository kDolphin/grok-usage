# Security Policy

**English** | **[简体中文](#安全说明)**

## Reporting a vulnerability

If you find a security issue in this project, please use [GitHub Security Advisories](https://github.com/kDolphin/grok-usage/security/advisories/new) (private report) or contact the maintainer privately.

**Do not** open a public issue that includes tokens, `auth.json` contents, or other credentials.

## What this app touches

- Reads `~/.grok/auth.json` (shared with Grok Build)
- May **write** OIDC access/refresh tokens to that file (browser device-code sign-in or token refresh)
- May **store** Cursor access/refresh tokens in this app’s Keychain (`com.kdolphin.grok-usage.bot`) after Bot browser login (Cursor PKCE)
- Optionally reads Grok Bot local secrets (`~/Library/Application Support/Grok Bot/sand-secrets.json`) + Keychain (`Grok Bot Safe Storage`) as a Bot fallback
- Network: `auth.x.ai` / `accounts.x.ai` (SuperGrok OIDC), `cli-chat-proxy.grok.com` (SuperGrok usage), `cursor.com` / `api2.cursor.sh` (Bot login + usage metadata only)

Never commit secrets, auth files, or screenshots that show your account email.

---

## 安全说明

**[English](#security-policy)** | **简体中文**

## 如何报告漏洞

若发现与本项目相关的安全问题，请通过 [GitHub Security Advisories](https://github.com/kDolphin/grok-usage/security/advisories/new) 私下报告，或私信维护者。

**请勿**在公开 Issue 中粘贴 token、`auth.json` 内容或其它凭证。

## 本应用会接触的数据

- 读取 `~/.grok/auth.json`（与 Grok Build 共用）
- 可能**写入** OIDC access / refresh token（浏览器设备码登录或自动续期）
- Bot 浏览器登录后可能把 Cursor access / refresh token **存入**本应用钥匙串（`com.kdolphin.grok-usage.bot`）
- 可选读取本机 Grok Bot 密钥（`sand-secrets.json` + `Grok Bot Safe Storage`）作为 Bot 后备
- 网络：`auth.x.ai` / `accounts.x.ai`（SuperGrok）、`cli-chat-proxy.grok.com`（SuperGrok 用量）、`cursor.com` / `api2.cursor.sh`（Bot 登录与用量元数据）

请勿将密钥、登录文件、或带有账号邮箱的截图提交到仓库。
