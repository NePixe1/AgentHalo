# Prompt for the macOS Codex reviewer

```text
请以 Agent Halo macOS 端维护者和跨平台架构审阅者身份，审阅当前仓库的
v0.12.0 shared-contract 实现。先不要修改代码。

当前架构：
- Windows：C# + WPF
- macOS：Swift + AppKit/Core Graphics
- 唯一共享参数源：shared/spec/agent-halo.v2.json
- 生成器：scripts/generate_shared.py
- Swift 生成文件：mac/Sources/AgentHaloCore/GeneratedHaloSpec.swift
- Windows 生成文件：windows/GeneratedHaloSpec.cs
- CI：.github/workflows/ci.yml

请先执行：
1. python3 scripts/generate_shared.py --check
2. python3 scripts/check_shared.py
3. cd mac && swift run AgentHaloCoreChecks
4. cd mac && swift build -c release --product AgentHaloMac
5. 如环境允许，运行 ./script/build_and_run.sh --verify

然后重点检查：
1. GeneratedHaloSpec.swift 是否符合 Swift 6 并发安全和 API 可见性要求。
2. SessionReducer、SessionAggregator、RateLimitReader、CodexFailureReader 接入生成规则后，
   是否保持 v0.11.1 行为。
3. HaloMath 与 HaloVisualModel 是否仍保持原视觉参数和数值精度。
4. macOS 专属 ringMorph、secondary contour、bloom 和 edge highlight 是否仍正确保持独立。
5. JSON Schema、生成器和 CI 是否存在 macOS 路径、换行或工具链问题。
6. 哪些剩余硬编码应迁入 shared spec，哪些必须继续留在 macOS renderer。
7. 当前 fixtures 是否足以证明 Windows 与 macOS 状态语义一致。
8. 是否存在会阻止合并或发布 v0.12.0 的问题。

请按以下格式回复：
- 结论：同意 / 修改后同意 / 不同意
- 阻塞问题
- 高风险行为差异
- Swift/构建问题
- Shared Spec 与代码生成建议
- 测试与 CI 缺口
- 应保持平台独立的内容
- 推荐修改顺序

请引用具体文件和行号，并区分“已验证事实”与“建议”。
```
