# IOHID 控制协议（phonebase-control）

云控基座通过局域网 WebSocket 接收 JSON 控制帧，经开源 **IOHID**（`STHIDEventGenerator`）注入系统触控 / 按键 / 硬件键。

> 画面走 TVH4（TCP `:5909`），与本协议无关。本文件只描述 **IOHID 控制面**。

---

## 1. 连接

| 项 | 值 |
|----|-----|
| 入口 | `ws://<手机局域网IP>:11019/control` |
| 子协议名（逻辑） | `phonebase-control` |
| 编码 | UTF-8 JSON 文本帧 |
| 坐标 | **归一化** `x,y ∈ [0,1]`，原点左上，与当前画面几何对齐 |
| 前置 | tipa 须 **TrollStore / 巨魔** 安装，否则 HID entitlement 无效 |

连接成功后服务端先发一条 `ready`，之后客户端发命令，服务端回 `ack`（`keepalive` 无回包）。

发现接口：`GET http://<IP>:11019/api/info`  
其中 `iohid: true`，`hidFeatures` 列出已实现的 `type` 能力。

---

## 2. 公共字段

### 2.1 客户端 → 手机（命令）

| 字段 | 类型 | 说明 |
|------|------|------|
| `type` | string | 命令类型，见下文 |
| `seq` | number | 可选；原样带回 `ack`，用于对账 |

各 `type` 另有专属字段。

### 2.2 手机 → 客户端（就绪）

```json
{
  "type": "ready",
  "protocol": "phonebase-control",
  "version": 1,
  "deviceId": "ios-xxxxxxxxxxxx",
  "controlAvailable": true,
  "homeAvailable": true,
  "textAvailable": true,
  "keyboardAvailable": true,
  "geometry": {
    "width": 1170,
    "height": 2532,
    "sourceWidth": 1170,
    "sourceHeight": 2532,
    "orientation": 1,
    "revision": 1,
    "changedAtUs": 0
  }
}
```

### 2.3 手机 → 客户端（应答）

```json
{ "type": "ack", "seq": 1, "ok": true }
```

失败时：

```json
{ "type": "ack", "seq": 1, "ok": false, "error": "bad coords" }
```

常见 `error`：`bad coords` / `bad text` / `bad key` / `unsupported button`。

未知 `type`：可能收到空处理或仅带 `seq` 的空成功 ack（实现以宿主为准）；客户端应只使用本文档列出的 `type`。

---

## 3. 命令一览

### 3.1 `keepalive`

心跳，**不回 ack**。

```json
{ "type": "keepalive", "seq": 1 }
```

---

### 3.2 `pointer` — 指针（按下 / 移动 / 抬起）

| 字段 | 必填 | 说明 |
|------|------|------|
| `action` | 是 | `down` / `move` / `up` / `cancel` |
| `x`, `y` | 除 `cancel` 外必填 | `[0,1]` |

```json
{ "type": "pointer", "seq": 1, "action": "down", "x": 0.5, "y": 0.5 }
{ "type": "pointer", "seq": 2, "action": "move", "x": 0.5, "y": 0.7 }
{ "type": "pointer", "seq": 3, "action": "up",   "x": 0.5, "y": 0.7 }
{ "type": "pointer", "seq": 4, "action": "cancel" }
```

`cancel`：在上次触点抬起（可省略合法坐标）。

---

### 3.3 `tap` / `doubleTap` / `longPress`

| 字段 | 必填 |
|------|------|
| `x`, `y` | 是 |

```json
{ "type": "tap", "seq": 1, "x": 0.5, "y": 0.4 }
{ "type": "doubleTap", "seq": 2, "x": 0.5, "y": 0.4 }
{ "type": "longPress", "seq": 3, "x": 0.5, "y": 0.4 }
```

---

### 3.4 `multitouch` — 多指

| 字段 | 默认 | 说明 |
|------|------|------|
| `action` | `tap` | `down` / `up` / `tap` |
| `count` | `2` | 指数量，实现侧通常夹到 1…5 |
| `x`, `y` | 必填 | 触点中心 |

```json
{ "type": "multitouch", "seq": 1, "action": "tap", "count": 2, "x": 0.5, "y": 0.5 }
```

`count=2` 的 `tap` → 双指轻点；`count≥3` → 三指轻点。

---

### 3.5 `drag` — 拖拽

| 字段 | 默认 | 说明 |
|------|------|------|
| `x0`,`y0` | 必填 | 起点 |
| `x1`,`y1` | 必填 | 终点 |
| `duration` | `0.25` | 秒 |
| `curve` | `false` | `true` 曲线插值，否则线性 |

```json
{
  "type": "drag", "seq": 1,
  "x0": 0.5, "y0": 0.8, "x1": 0.5, "y1": 0.2,
  "duration": 0.4, "curve": false
}
```

---

### 3.6 `pinch` — 捏合

矩形为归一化包围盒（左上 + 宽高）；`scale` 为目标缩放相对量（实现透传上游）。

| 字段 | 默认 |
|------|------|
| `x`,`y` | 必填（矩形左上） |
| `w`,`h` | `0.4` |
| `scale` | `0.5` |
| `angle` | `0`（弧度） |
| `duration` | `0.35` |

```json
{
  "type": "pinch", "seq": 1,
  "x": 0.3, "y": 0.3, "w": 0.4, "h": 0.4,
  "scale": 0.5, "angle": 0, "duration": 0.35
}
```

---

### 3.7 `stylus` — 手写笔

| 字段 | 默认 | 说明 |
|------|------|------|
| `action` | `tap` | `down` / `move` / `up` / `tap` |
| `x`,`y` | 必填 | |
| `azimuth` | `0` | 方位角 |
| `altitude` | `π/4` | 倾角 |
| `pressure` | `0.5` | 压力 |

```json
{
  "type": "stylus", "seq": 1, "action": "tap",
  "x": 0.5, "y": 0.5, "azimuth": 0, "altitude": 0.785, "pressure": 0.6
}
```

---

### 3.8 `button` / `home` — 硬件与系统键

`home` 为简写，等价于 `button=home`。

| 字段 | 默认 | 说明 |
|------|------|------|
| `button` | `home` 类型可省略 | 见下表 |
| `action` | `press` | 见下表（因按键而异） |

**`button` 取值**

| button | 含义 |
|--------|------|
| `home` / `menu` | Home / Menu |
| `power` | 电源 |
| `mute` | 静音键 |
| `volumeUp` / `vol+` / `volume+` | 音量+ |
| `volumeDown` / `vol-` / `volume-` | 音量- |
| `brightnessUp` / `bright+` | 亮度+ |
| `brightnessDown` / `bright-` | 亮度- |
| `snapshot` / `screenshot` | 截屏组合 |
| `shake` | 摇一摇 |
| `lock` / `unlock` | 硬件锁 / 解锁 |
| `keyboard` | 切换屏幕键盘 |
| `spotlight` | Spotlight |

**`action` 取值（子集）**

| action | 适用 |
|--------|------|
| `press` | 多数键单击 |
| `double` | home、power |
| `triple` | power |
| `long` | home、power |
| `down` / `up` | home、power、mute、音量、亮度（按住/松开） |

```json
{ "type": "home", "seq": 1 }
{ "type": "button", "seq": 2, "button": "power", "action": "press" }
{ "type": "button", "seq": 3, "button": "volumeUp", "action": "press" }
{ "type": "button", "seq": 4, "button": "snapshot" }
```

---

### 3.9 `text` — 文本注入

| 字段 | 约束 |
|------|------|
| `text` | 非空，UTF-8 长度 ≤ 4096 |

按字符走 HID 键盘用法；**非 ASCII（如中文）可能无效**，属上游 HID 键盘限制。

```json
{ "type": "text", "seq": 1, "text": "hello" }
```

---

### 3.10 `key` — 单键

| 字段 | 默认 | 说明 |
|------|------|------|
| `key` | 必填 | 见映射表；也可传单字符 |
| `action` | `press` | `press` / `down` / `up` |

**常用 `key` 别名 → 内部 HID 名**

| key | 说明 |
|-----|------|
| `backspace` / `delete` | 退格 |
| `enter` / `return` | 回车 |
| `tab` | Tab |
| `escape` / `esc` | Esc |
| `left` / `right` / `up` / `down` | 方向键 |
| `home` / `end` / `pageup` / `pagedown` | 导航 |
| `space` | 空格 |

```json
{ "type": "key", "seq": 1, "key": "enter", "action": "press" }
{ "type": "key", "seq": 2, "key": "a", "action": "down" }
{ "type": "key", "seq": 3, "key": "a", "action": "up" }
```

---

### 3.11 `keysRelease`

松开当前记录的全部按键状态。

```json
{ "type": "keysRelease", "seq": 1 }
```

---

### 3.12 `hidKeepAlive`

设置 HID 层保活定时器（秒）。`0` 关闭。

```json
{ "type": "hidKeepAlive", "seq": 1, "interval": 30 }
```

---

## 4. 与画面的关系

| 通道 | 端口 | 用途 |
|------|------|------|
| TVH4 视频 | `5909` TCP | H.264 画面 |
| HTTP / WS | `11019` | `/api/info`、`/control`、可选 `/video` WS |

控制坐标按 **归一化** 发送，与 TVH4 分辨率无关；旋转后应以 `ready.geometry` / `/api/info` 的宽高理解朝向。

---

## 5. 实现位置（源码）

| 路径 | 作用 |
|------|------|
| `App/IOHIDBridge.*` | ObjC 封装上游 IOHID API |
| `App/IOHIDController.swift` | Swift 入口 |
| `App/AppRuntime.swift` → `handleControl` | 本协议解析 |
| `Shared/LocalService.swift` | `/control` WebSocket、`/api/info` |
| `App/Vendor/STHID/` | 开源 `STHIDEventGenerator`（GPL-2） |

---

## 6. 最小联调示例

```text
1. GET  http://PHONE:11019/api/info   → 确认 iohid / controlAvailable
2. WS   ws://PHONE:11019/control      → 收到 ready
3. 发送 { "type":"tap", "seq":1, "x":0.5, "y":0.5 }
4. 收到 { "type":"ack", "seq":1, "ok":true }
5. 发送 { "type":"button", "seq":2, "button":"home", "action":"press" }
```
