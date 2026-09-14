# Security Policy

**English** | **[简体中文](#安全说明)**

## Reporting a vulnerability

If you find a security issue in this project, please use [GitHub Security Advisories](https://github.com/kDolphin/grok-usage/security/advisories/new) (private report) or contact the maintainer privately.

**Do not** open a public issue that includes tokens, `auth.json` contents, or other credentials.

## What this app touches

- Reads `~/.grok/auth.json` (shared with Grok Build)
- May **write** updated OIDC access/refresh tokens back to that file
- Reads Grok Bot local secrets (`~/Library/Application Support/Grok Bot/sand-secrets.json`) and unlocks them via Keychain (`Grok Bot Safe Storage`) to fetch Bot weekly usage
- Network: `auth.x.ai` (token refresh), `cli-chat-proxy.grok.com` (SuperGrok usage metadata), `api2.cursor.sh` (Grok Bot usage metadata only)

Never commit secrets, auth files, or screenshots that show your account email.

---

## 安全说明

**[English](#security-policy)** | **简体中文**

## 如何报告漏洞

若发现与本项目相关的安全问题，请通过 [GitHub Security Advisories](https://github.com/kDolphin/grok-usage/security/advisories/new) 私下报告，或私信维护者。

**请勿**在公开 Issue 中粘贴 token、`auth.json` 内容或其它凭证。

## 本应用会接触的数据

- 读取 `~/.grok/auth.json`（与 Grok Build 共用）
- 自动续期时可能**写回** access / refresh token
- 读取 Grok Bot 本地密钥（`~/Library/Application Support/Grok Bot/sand-secrets.json`），并通过钥匙串（`Grok Bot Safe Storage`）解密以获取 Bot 周用量
- 网络：`auth.x.ai`（续期）、`cli-chat-proxy.grok.com`（SuperGrok 额度元数据）、`api2.cursor.sh`（仅 Grok Bot 额度元数据）

请勿将密钥、登录文件、或带有账号邮箱的截图提交到仓库。
