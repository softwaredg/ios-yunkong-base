# IOS 云控基座（TVH4 + IOHID）

对标商业版 **DirectPhoneBase** 路线：**不越狱、不用 VNC**。

| 层 | 方案 |
|------|------|
| 采屏 | 私有 `CARenderServer` + `IOSurface`（TrollStore tipa 权限） |
| 编码 | VideoToolbox H.264 |
| 推流 | TVH4 TCP `:5909` |
| 控制 | 开源 IOHID → `ws://手机:11019/control` |
| 电脑解码 | WebCodecs（PC 端已有） |
| 自愈 | 内存守护整机软重启 + 采屏 IOSurface 重建 |
| 兜底 | 前台窗口快照；ReplayKit 扩展仅保留作备用，主路径不弹录屏授权 |

## 端口

| 服务 | 地址 |
|------|------|
| HTTP /control /video | `:11019` |
| TVH4 视频 | `:5909` |

## IOHID 协议

完整字段见 **[IOHID协议.md](./IOHID协议.md)**。

## 打 tipa

须 Mac / GitHub Actions + **TrollStore**（私有 entitlement）。源码 HID：`App/Vendor/STHID/`（GPL-2）。
