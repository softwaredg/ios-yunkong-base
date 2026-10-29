# IOS 云控基座（TVH4 + IOHID）

- **画面**：TVH4 TCP `:5909`
- **控制**：`ws://手机:11019/control` → 开源 **IOHID**（`STHIDEventGenerator`）

## 端口

| 服务 | 地址 |
|------|------|
| HTTP /control /video | `:11019` |
| TVH4 视频 | `:5909` |

## IOHID 协议

完整字段、示例与联调步骤见 **[IOHID协议.md](./IOHID协议.md)**。

## 打 tipa

须 Mac / GitHub Actions + **TrollStore**（HID 私有权限）。源码：`App/Vendor/STHID/`（GPL-2）。
