# PhoneBaseLocal（非商业手机基座 · 可 Xcode 打包）

按 `文档/protocol` 重写的 **Swift 源码工程**，`licenseRequired=false`，对接本仓库 Electron / local-client。

> 本机 Windows **不能**出 IPA。请拷到 **Mac + Xcode** 生成工程并打包。

## 能力现状

| 模块 | 状态 |
|---|---|
| `GET /api/info` `/api/health` | 已实现，`licenseRequired: false` |
| `WS /video` + PHB1 H.264 | 已实现（应用内演示画面编码） |
| `WS /control` pointer/home/text/key | 已实现；优先 `IOHIDTouchInjector`，否则仅日志 |
| 系统级 IOHID 触控 / 键盘 | **代码已写**（`Control/IOHIDTouchInjector.swift`）；需 TrollStore + entitlements |
| 系统级全屏截屏 | **未做**（仍用应用内演示画面；可换 `ScreenSampler`） |

键盘/点控：Mac 打包后用 **TrollStore** 安装（`PhoneBaseLocal.entitlements` 含 HID 私有权限）。普通企业签多半 `textAvailable=false`、注入无效。  
全机投屏画面仍要另接系统采集；当前默认仍是演示帧。

## Mac 打包步骤

1. 安装 [Xcode](https://developer.apple.com/xcode/)（15+）与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：
   ```bash
   brew install xcodegen
   ```
2. 生成工程并打开：
   ```bash
   cd 应用/本地基座-iOS
   xcodegen generate
   open PhoneBaseLocal.xcodeproj
   ```
3. Xcode 里选你的 Team（Signing），真机或模拟器 Run。
4. 打 IPA（任选）：
   - **开发调试**：Run 到已信任的真机  
   - **Ad Hoc / 企业**：Product → Archive → Distribute  
   - **TrollStore**：Archive 导出未签名/重签 IPA，或用 `xcodebuild` 后 `ldid`/TrollStore 安装流程  

5. 手机打开「本地基座」→ 保持服务运行 → 电脑 Electron「本地投屏」填手机 IP、端口 `11019`。

现成可装包（不必自己先编过）：仓库 `安装包/PhoneBase-Local-v0.12.2.ipa`。

## 目录

```
PhoneBaseLocal/
  App/           UI 与启动
  Service/       BaseRuntime、设备 ID
  Net/           HTTP + WebSocket
  Video/         PHB1、H264、采样
  Control/       控制协议与触控接口
```

## 与商业基座区别

- Bundle ID：`cn.local.phonebase.local`
- **无**商业 license / 云校验
- 协议兼容 `lan-phonebase` + PHB1 + phonebase-control v1
