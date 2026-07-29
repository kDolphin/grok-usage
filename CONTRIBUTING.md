# Contributing

感谢关注。本项目很小，欢迎 Issue / PR。

## 开发

```bash
swift run GrokUsage
# 或
./Scripts/run.sh
```

## 改代码时的约定

1. `./Scripts/bump-patch.sh` 递增补丁版本  
2. `git commit`（含 `VERSION` / `BUILD` / `AppVersion.swift`）  
3. `./Scripts/build-app.sh` 验证能打出 `.app`

详见 [AGENTS.md](AGENTS.md)。

## PR 建议

- 说明动机与行为变化  
- 若改刷新/鉴权/告警逻辑，写明对请求频率与隐私的影响  
- 勿提交密钥、`~/.grok` 内容、含真实账号信息的截图  
