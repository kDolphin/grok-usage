# Security

## 报告问题

若发现与本工具相关的安全问题，请优先通过 GitHub Security Advisory（Private vulnerability reporting）或私信维护者，避免公开 Issue 贴出 token。

## 本工具会接触的敏感数据

- `~/.grok/auth.json` 中的 OIDC access / refresh token（与 Grok Build 共用）  
- 自动续期时会**写回**该文件  

请勿把 `auth.json`、导出的 token、或带真实邮箱/账号的调试日志提交到仓库。

## 范围

本项目是非官方客户端，仅请求额度元数据与 OIDC 续期；不代理你的对话内容。
