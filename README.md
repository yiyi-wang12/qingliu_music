# 清流音乐

局域网音乐播放器。Windows 上跑一个单文件 Python 服务端扫描本机音乐，安卓端用 Flutter 播放，带歌词滚动、封面、收藏、歌单和离线缓存。

服务端只用 Python 标准库，**不需要 pip install**；客户端是标准 Flutter 工程，可直接构建 APK。

- 作者：**yiyi-wang12**
- 许可证：**GPL-3.0**（见 [LICENSE](LICENSE)）
- 服务端：`server/`（Python 3.8+）
- 客户端：`qingliu/`（Flutter，包名 `com.yiyiwang12.qingyunmusic`）

> 本软件仅提供本地音乐文件的播放能力，**不提供、不内置、不分发任何音乐及歌词内容**。仓库只包含代码，不含音乐、歌词、封面文件和构建产物；`server/music`、`server/lrc`、`server/images` 需自行放文件，APK 走 Releases 发布，不提交进仓库。

---

## 目录结构

```
.
├─ server/                 服务端
│  ├─ main.py              HTTP 服务、扫描、流式传输、收藏与歌单接口
│  ├─ setting.py           账号管理（交互菜单 / 命令行）
│  ├─ setting.json         首次运行自动生成（含签名密钥，不入库）
│  ├─ user.json            账号，PBKDF2-SHA256 加盐哈希（不入库）
│  ├─ library.json         收藏与歌单（不入库）
│  ├─ music/               音乐目录，递归扫描（内容不入库）
│  ├─ lrc/                 歌词目录（内容不入库）
│  └─ images/              封面目录（内容不入库）
├─ qingliu/                安卓客户端（Flutter 工程）
├─ LICENSE                 GPL-3.0 许可证全文
└─ 打包APK.md               构建命令速查
```

---

## 一、服务端

### 启动

```powershell
python main.py
```

启动后会打印监听地址与局域网地址：

```
  监听地址  : 0.0.0.0:8080
  局域网访问: http://192.168.1.10:8080
```

把这个地址填进 App 的「服务器地址」。默认账号 **admin / admin123**，首次登录后请立即修改。

### 账号管理

```powershell
python setting.py                          # 交互菜单：添加 / 删除 / 改名 / 改密码
```

也可以直接下命令（`main.py user` 是等价写法）：

```powershell
python setting.py list                     # 列出账号
python setting.py add 张三 密码123          # 新增
python setting.py del 张三                 # 删除
python setting.py rename 张三 李四          # 改名，收藏和歌单跟着走
python setting.py passwd admin 新密码       # 改密码
```

服务端按 `user.json` 的修改时间自动重读，改完**立即生效，不用重启**。改名后旧用户名的 token 失效，收藏与歌单一起迁到新用户名下。

要强制所有客户端重新登录，改 `setting.json` 里的 `secret`（换成任意另一串）再重启。

### 配置项（setting.json）

首次运行自动生成，字段缺失会补默认值。

| 字段 | 默认值 | 说明 |
|---|---|---|
| `server_name` | 音乐服务器 | 显示在 App 首页与设置页 |
| `host` | 0.0.0.0 | 监听地址，`0.0.0.0` 表示局域网可访问 |
| `port` | 8080 | 端口，改完重启生效 |
| `music_dir` | music | 音乐目录，相对 `main.py` 所在目录 |
| `lrc_dir` | lrc | 歌词目录 |
| `images_dir` | images | 封面目录 |
| `token_hours` | 720 | 登录有效期（小时） |
| `scan_cache_seconds` | 5 | 曲库扫描缓存，改文件后最多 5 秒生效 |
| `chunk_size` | 262144 | 流式传输分块大小（256 KB），客户端也读这个值 |
| `secret` | 随机生成 | token 签名密钥。删掉会自动重建，代价是所有客户端需重新登录 |

### 文件放哪

**音乐** — 丢进 `server/music/`，支持子目录，递归扫描：

```
music/周杰伦/夜曲.flac
music/夜曲.mp3
```

支持 mp3 / flac / m4a / aac / ogg / opus / wav / wma / ape / alac / aiff / aif / m4b。歌名、艺术家、专辑优先读 ID3 / Vorbis 标签，没有就用文件名。

**歌词** — 丢进 `server/lrc/`，`.lrc` 格式，按歌名匹配。以下命名都能命中 `music/02 - 某人 - 晴天.flac`：

```
lrc/晴天.lrc
lrc/某人 - 晴天.lrc
lrc/02 - 某人 - 晴天.lrc
lrc/晴天.LRC
```

也支持把 `.lrc` 放在音乐文件旁边。

**封面** — 丢进 `server/images/`，按歌名匹配，jpg / png / webp 都行：

```
images/夜曲.jpg           与歌曲同名（推荐）
images/cover.jpg          整个目录通用封面
images/周杰伦/夜曲.jpg     与 music 子目录结构对应
```

也支持放在音乐同目录（同名，或 `cover.jpg` / `folder.jpg`）。没有封面的歌显示渐变图标占位。

### 接口

除 `/api/ping`、`/api/login` 外都需要鉴权：`Authorization: Bearer <token>`，或 URL 加 `?token=`（播放器取音频、图片用）。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/ping` | 探活，登录前可用 |
| POST | `/api/login` | `{username, password}` → `{token}` |
| GET | `/api/config` | 客户端分块大小等配置 |
| GET | `/api/songs` | 全部歌曲，`?refresh=1` 强制重扫 |
| GET | `/api/stream/<id>` | 音频流，支持 Range（206） |
| GET | `/api/lrc/<id>` | 歌词原文 |
| GET | `/api/cover/<id>` | 封面图片 |
| GET | `/api/library` | 收藏 + 歌单 |
| POST | `/api/favorites/toggle` | `{song_id}` 收藏 / 取消，新收藏排最前 |
| POST | `/api/favorites/batch` | `{song_ids: [...], action: add\|remove}`，已存在（或不存在）的自动跳过 |
| POST | `/api/favorites/order` | `{songs: [id...]}` 保存收藏顺序 |
| POST | `/api/playlists` | `{name}` 新建歌单 |
| DELETE | `/api/playlists/<pid>` | 删除歌单 |
| POST | `/api/playlists/<pid>/songs` | `{song_id}` 加入，新加的排最前 |
| POST | `/api/playlists/<pid>/songs/batch` | `{song_ids: [...]}` 批量加入，已含的跳过 |
| POST | `/api/playlists/<pid>/songs/remove` | `{song_ids: [...]}` 批量移除，不在的跳过 |
| POST | `/api/playlists/<pid>/order` | `{songs: [id...]}` 保存歌单顺序 |
| DELETE | `/api/playlists/<pid>/songs/<sid>` | 移出单曲 |

顺序接口只接受列表里已有的歌，漏掉的补在末尾，不会因为少传就丢数据。

### 网络

- 服务端是 **HTTP**，没有 HTTPS。客户端在 `AndroidManifest.xml` 里开了 `usesCleartextTraffic="true"`，否则 Android 9+ 直接拒绝明文请求。
- Windows 防火墙首次会弹窗，选「允许专用网络」，否则手机连不上。
- 手机与电脑必须在同一局域网 / 同一 WiFi。
- 端口被占用时 Windows 允许两个进程 bind 同一端口，旧进程会抢走连接，表现为「改了代码却没生效」。先查再杀：

```powershell
netstat -ano | findstr :8080
taskkill /PID <上面查到的PID> /F
```

---

## 二、安卓客户端

### 构建

```powershell
cd qingliu
flutter pub get
flutter build apk --release
```

产物在 `qingliu/build/app/outputs/flutter-apk/app-release.apk`。要求 Flutter SDK 3.x（Dart >= 3.0），JDK 17。Android 侧需要 NDK `28.2.13676358`，缺失时构建会直接报错。

### 功能

**首次登录**：服务器地址（`192.168.1.10:8080` 或 `http://192.168.1.10:8080` 都行，自动补协议）、用户名、密码。之后自动登录，token 默认有效 30 天。

**底部三栏**

| 栏 | 内容 |
|---|---|
| 首页 | 搜索（歌名 / 歌手 / 专辑 / 目录）+ 全部歌曲，点歌即入队并进播放页 |
| 我的 | 我的收藏、我的歌单、新建歌单；歌单可增删（新加排最前）；收藏与歌单支持「调整顺序」长按拖动 |
| 设置 | 服务器地址、账号密码、主题颜色（红橙黄绿蓝靛紫 7 组 × 6 档深浅）、玻璃效果开关、歌词字号 14–36、播放设置、缓存管理、关于、退出登录 |

**液体玻璃**：默认开启，可关闭回到纯色界面。分四层：边缘折射带（靠近边缘一圈单独采样背景并放大，边缘位移最大，形成透镜）、主体模糊（挖掉折射带，不重叠）、极淡白雾（只负责体积感）、边缘（厚度暗边与一整圈高光是单层连续路径填充，没有多层描边叠出来的接缝）。背后颜色额外套一层饱和度增益。

应用位置：底部导航是一块悬浮玻璃胶囊（有歌时包住迷你播放器），列表从底下滚过；首页搜索栏、各二级页面的玻璃标题栏、设置页与我的页的分组卡片、确认弹窗、三点菜单、加入歌单弹层。**播放页歌词不是面板，而是每个字本身做成玻璃字**：半透明填充 + 亮描边 + 上半段反光 + 落影，正在唱的那行描边走主题色。

**播放页**：大封面、滚动歌词（当前行严格居中，唱过的字逐个变主题色，可拖动进度），上 / 下一首、播放模式、收藏、加入歌单。点歌词任意一行跳到那句的时间点继续播放。

**锁屏 / 通知栏 / 灵动岛**：歌名、歌手、封面、上一首 / 播放暂停 / 下一首 / 进度拖动，走 Android 原生 MediaSession + MediaStyle 通知（`android/.../MediaPlayback.kt`），不依赖第三方插件；播放期间前台服务常驻，熄屏、锁屏、切后台都不断。

**点歌行为**：正在放的那首再点一次只打开播放页，不重新加载；同一列表换歌只做切片，不重建整个队列。

**多选**：首页、我的收藏、任意歌单都支持。长按任意一首进入多选（歌单页标题栏另有按钮），点条目切换勾选，标题栏右侧全选 / 取消全选，左侧叉号退出。底部浮出玻璃操作栏，按页面给不同动作：

| 页面 | 动作 |
|---|---|
| 首页 | 收藏、取消收藏、加入歌单、缓存、删缓存 |
| 我的收藏 | 取消收藏、加入歌单、缓存、删缓存 |
| 歌单 | 收藏、加入歌单、移出歌单、缓存、删缓存 |

已在目标里的自动跳过，做完弹一句「已…… N 首，跳过 M 首」。

**播放设置**：自动连播、播放模式（列表循环 / 单曲循环 / 随机播放）。所有歌曲都从头播放，不记忆上次进度。

### 离线缓存

设置页有「播放时自动缓存」开关，打开后一首歌一开播就把整首拉到本地，边播边下；每首歌的三点菜单里另有「添加缓存」，不受开关影响，连点几首会排队逐首下。

- 播放本身**不落盘**：播放器连本机回环代理（`chunk_stream.dart`），代理按 `chunk_size` 一块块从服务器拉，当前块交给播放器的同时下一块已发出；播放器不取数据时 `flush()` 挂住，最多压两块在内存里
- 缓存是另一路整首下载，与播放并行：播放一进缓冲下载就让路，缓冲够了再继续
- 缓存位置：应用私有目录 `music_cache/{audio,lrc,cover}` + `manifest.json`
- 写盘分两条连接（手动 4 条 / 播放时 2 条）各写段文件 `audio/{id}.{ext}.p0 / .p1 …`，追加打开，**段文件多长就代表那段下到哪**；布局与版本指纹记在 `{id}.{ext}.p.json`。全部段齐了才拼成 `.merging`，校验总长度后改名进缓存，残缺文件不会当成缓存
- **断点续传**：手动队列写进 `queue.json`，重开应用登录后自动接着下；播放时顺手下的按段文件长度续，切歌、杀进程、断网都不丢已下部分
- 校验方式：服务端为每首歌下发 `version` / `lrc_version` / `cover_version`（文件大小 + 修改时间指纹），任一版本对不上只重下那一个文件。换音频、改歌词、换封面都会自动更新，不用手动清缓存
- 命中缓存直接播本地文件，没命中走网络流
- 换服务器登录时自动清空缓存，避免同名 id 指向另一台机器上的另一首歌
- 「缓存管理」页：显示「N 首 · 共 XX MB」，下载中的排前面并带进度条与「已下 / 总大小」，可单独取消；已完成的列出音频 / 歌词 / 封面各自大小与缓存时间，可单曲删除，右上角清空

### 代码结构

```
qingliu/lib/
  main.dart               入口、主题、启动页、自动登录判定
  api.dart                HTTP 客户端（登录、曲库、流地址、歌词、封面、收藏、歌单）
  models.dart             Song / Playlist / LyricLine，LRC 解析，格式化工具
  app_state.dart          全局状态（服务器、账号、设置项、缓存开关）
  player_controller.dart  播放队列、播放模式
  cache_service.dart      缓存下载、版本校验、统计与清理
  chunk_stream.dart       本机回环分块代理（边拉边播，预取下一块）
  media_session.dart      锁屏 / 通知栏 / 灵动岛（channel: qingliu/media）
  theme.dart              主题与玻璃色板
  pages/                  login / shell / home / mine / song_list / player / settings / cache
  widgets/                cover_art / song_tile / mini_player / play_action / liquid_glass / selection

qingliu/android/app/src/main/kotlin/com/yiyiwang12/qingyunmusic/
  MainActivity.kt         注册 qingliu/media 通道
  MediaPlayback.kt        MediaSession、MediaStyle 通知、封面、按钮事件
  MediaPlaybackService.kt 播放期间的前台服务
```

---

## 三、已知坑

| 现象 | 原因 | 处理 |
|---|---|---|
| Gradle 报 `project path contains non-ASCII characters` | 工程路径含中文 | 放在纯 ASCII 路径下构建 |
| 手机连不上 / 报 network error | 防火墙、明文 HTTP、不同网段 | 放行专用网络；确认 `usesCleartextTraffic="true"` 在清单里 |
| 改了 `main.py` 行为没变 | 旧进程仍占端口 | `netstat -ano \| findstr :8080` 查 PID 后 taskkill |
| 构建报 NDK 缺失 | 需要 NDK `28.2.13676358` | 在 Android SDK Manager 里装对应版本 |
| 歌词整体偏移 | 行高与滚动偏移不匹配 | 用固定行高 `itemExtent`，偏移 = `index × 行高`，当前行居中 |

---

## 免责声明与版权

本软件为局域网音乐播放工具，仅提供音乐文件的扫描、传输与播放功能，**不提供、不内置、不分发任何音乐作品、歌词或封面内容**。软件本身不含任何音频资源，客户端展示的曲库全部来自使用者自行搭建的服务器；音乐、歌词、封面均由使用者自行导入，使用者应确保相关内容来源合法并拥有相应使用权。因使用本软件播放或传播未经授权内容而产生的法律责任，由使用者自行承担。

本项目不包含任何绕过版权保护的技术手段，也不提供音乐下载、抓取、搜索或分发服务。若权利人认为本项目存在侵权内容，可通过仓库 Issue 与作者联系，我们将及时处理。

- 仓库内**不包含任何音乐、歌词、封面素材**，`server/music`、`server/lrc`、`server/images` 需自行放文件，请使用你拥有合法权利的内容。
- 代码仅供学习与自用；服务端只把使用者自己机器上的文件路由给同一局域网内的设备，不向公网分发。
- 作者：**yiyi-wang12**。

---

## 许可证

本项目以 **GNU General Public License v3.0** 发布，许可证全文见 [LICENSE](LICENSE)。
