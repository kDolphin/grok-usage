# Grok Usage

**[English](README.md)** | **简体中文**

轻量 macOS 菜单栏应用：显示 **SuperGrok 周用量**、**Grok Bot 周用量**（独立配额）与 **下次重置倒计时**。

<p align="center">
  <img src="https://img.shields.io/badge/version-0.3.0-blue" />
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" />
  <img src="https://img.shields.io/badge/license-MIT-orange" />
</p>

> **非官方项目。** 使用与 Grok Build CLI 相同的本地登录态与额度元数据接口，xAI 变更时可能失效。

## 功能

- **菜单栏读数** — 如 `Grok 46% · Bot 34% · 4d5h`
- **下拉详情** — SuperGrok 进度、产品占比、额外额度，以及独立的 Grok Bot 周用量
- **后台刷新** — 清醒时约每 20 分钟；睡眠时不请求
- **阈值告警** — 20 / 40 / 60 / 80 / 90 / 95 / 98% 每档每周期一次（SuperGrok 与 Bot 各自独立）
- **登录时启动**
- **自动续期 token** — 用 `refresh_token` 刷新（一般不必每天重新登录）
- **语言** — 跟随 macOS（英/简中），支持「为 App 单独设置语言」

## 截图

<p align="center">
  <img src="screenshot/popover-en.png" alt="Grok Usage 菜单面板" width="320" />
</p>

## 安装

### 下载（推荐）

从 [Releases](https://github.com/kDolphin/grok-usage/releases) 下载最新 `GrokUsage.zip`：

1. 解压
2. 将 `Grok Usage.app` 拖入 `/Applications`
3. 首次启动：右键 → **打开**（未公证签名）

### 从源码构建

```bash
git clone https://github.com/kDolphin/grok-usage.git
cd grok-usage
bash build.sh
open "build/Grok Usage.app"
```

安装：

```bash
cp -R "build/Grok Usage.app" /Applications/
```

## 系统要求

- macOS 13 或更高
- 已安装 [Grok Build](https://x.ai/build) 并至少登录过一次（`~/.grok/auth.json`）
- 可选：已登录 [Grok Bot](https://grok.com/bot)（用于独立的 Bot 周用量）

```bash
grok login   # 从未登录时才需要
```

## 使用

1. 打开 **Grok Usage**，菜单栏出现状态。
2. 点击查看详情与操作。
3. 需要开机启动时打开 **登录时启动**。
4. 允许通知以接收阈值告警。

## 隐私

| 行为 | 说明 |
|------|------|
| 读取 | `~/.grok/auth.json`（与 Grok Build 共用）；Grok Bot 本地密钥 + 钥匙串（仅 Bot 用量） |
| 写入 | 续期时可能更新 `auth.json` 中的 token |
| 网络 | `auth.x.ai`、`cli-chat-proxy.grok.com`（SuperGrok）、`api2.cursor.sh`（Grok Bot） |
| 不上传 | 代码、会话、工程文件 |

不调用大模型，只读额度元数据。

## 故障排查

| 现象 | 处理 |
|------|------|
| 未登录 | 运行一次 `grok` 或 `grok login` |
| 续期失败 | 运行一次 `grok` |
| 无通知 | 系统设置 → 通知 → Grok Usage |
| 开机启动失败 | 使用 `/Applications` 中的副本并在登录项中允许 |
| 无法切换语言 | 使用 `bash build.sh` 构建的版本（含 en / zh-Hans） |

## 技术栈

- Swift / SwiftUI `MenuBarExtra`
- 无第三方依赖

## 目录结构

```text
GrokUsage/                 # 应用本体（源码 + 本地化 + 图标）
  *.swift
  Info.plist
  en.lproj/  zh-Hans.lproj/
  Resources/AppIcon.icns
build.sh                   # → build/Grok Usage.app + GrokUsage.zip
screenshot/                # README 截图
```

## License

[MIT](LICENSE)
