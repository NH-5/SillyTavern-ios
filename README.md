# SillyTavern

LLM Frontend for Power Users

## iOS 原生客户端（本仓库的 dsh 分支）

本分支在原有 SillyTavern 之上增加了一个**完全离线的原生 iOS 客户端**，位于 [`ios/`](ios/README.md)。

它不连接 SillyTavern 服务器：角色卡解析、世界书触发、Prompt 组装、Token 预算全部在
设备本地用 Swift 实现，只把最终请求发给你选择的模型供应商。导出的角色卡（PNG）、
聊天记录（JSONL）、世界书（JSON）与桌面版 SillyTavern 保持格式互通。

```sh
# 用 Xcode 打开
open ios/SillyTavern.xcodeproj

# 或命令行构建到模拟器
ios/scripts/build.sh --screenshot

# 跑核心逻辑测试（不需要模拟器）
ios/scripts/test.sh
```

兼容性依据（每一条规则都标注了对应的源码文件与行号）见 [`docs/ios-research/`](docs/ios-research/)。

## Resources

- GitHub: <https://github.com/SillyTavern/SillyTavern>
- Docs: <https://docs.sillytavern.app/>
- Discord: <https://discord.gg/sillytavern>
- Reddit: <https://reddit.com/r/SillyTavernAI>

## License

AGPL-3.0
