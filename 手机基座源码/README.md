# IOS 云控基座（PHB1 + IOHID）

源码已替换为投屏解包 `PhoneBaseLocal`：画面 **PHB1 H.264 over WS `/video`**，控制 **`/control`**。无 VNC / TVH4 / `:5909`。

| 层 | 方案 |
|------|------|
| 采屏 | `CARenderServer` + IOSurface（失败则演示帧） |
| 编码 | VideoToolbox H.264 |
| 推流 | `ws://手机:11019/video`（PHB1） |
| 控制 | IOHID → `ws://手机:11019/control` |
| USB | 同协议端口 `11021` |
| 电脑解码 | WebCodecs（PC 端） |

## 端口

| 服务 | 地址 |
|------|------|
| HTTP / WS `/video` `/control` | `:11019` |
| USB 同协议 | `:11021` |

## 打 tipa

须 Mac / GitHub Actions + **TrollStore**。源码在 `PhoneBaseLocal/`。打包脚本仍产出 `IOSYunKongBase.app`。

**不要擅自打包**——等产品明确说「打包」再打。

旧 TVH4 树已归档到 `归档/基座研发/旧TVH4基座-*`。
