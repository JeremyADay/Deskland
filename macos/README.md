# Deskland Preview for macOS (host)

**English** · [简体中文](#中文说明)

A small native macOS host that runs Deskland's two open-source themes, Meadow (`prototype/meadow.html`)
and Beach (`prototype/flat.html`), as a live desktop wallpaper that forms around the real desktop
icons. The theme pages run unchanged. This folder is the Mac counterpart of `host/` (the Windows
host) and is licensed under the same GPL-3.0 as the rest of the repository (see `LICENSE`, `NOTICE`,
`THIRD_PARTY_NOTICES.md` and `TRADEMARKS.md` at the top level).

Parts of the window, web view and Accessibility code are adapted from Desk Critters, also by Jeremy
Day, and are released here under GPL-3.0.

## Build

```sh
tools/make-mac.sh            # writes ".capture/dist/Deskland Preview.app" and prints its path
tools/make-mac.sh <dir>      # or "<dir>/Deskland Preview.app"
```

It needs the Xcode command line tools (`swiftc`) and nothing else. It builds a universal binary
(Apple silicon and Intel, macOS 13 or later), copies `prototype/` into
`Contents/Resources/prototype`, takes the version from `tools/version.json`, and signs the app ad hoc.

## Run

Quit any other live wallpaper first, then open `Deskland Preview.app`. A leaf appears in the menu
bar (no Dock icon). The menu has: Themes (Meadow / Beach, remembered), Pause animation, Reload,
Grant Accessibility… (only until it is granted), About, and Exit (restore wallpaper). The menu is in
Simplified Chinese when the Mac's preferred language is Chinese, otherwise English.

- Only one copy runs at a time; opening it again does nothing.
- Exit (or a log out, or `kill`) removes the wallpaper window, so the normal desktop picture is
  back at once.
- Its own identity, apart from other Deskland builds: bundle id `app.deskland.preview.mac`;
  settings in that UserDefaults domain, the instance lock in
  `~/Library/Application Support/app.deskland.preview.mac/`.
- It pauses while one window covers essentially the whole main screen (85% or more: zoomed or full
  screen), while the display sleeps, the screen is locked or the screen saver runs, or when
  Pause is checked.
- Frame rate: the pages cap themselves at 30 fps (`cap30`, on by default). The host adds no timer
  or display link that drives frames; WebKit runs the page's `requestAnimationFrame` as usual.

## Accessibility permission

Finder only tells another app where the desktop icons are through Accessibility. Choose Grant
Accessibility… in the menu, or turn on **Deskland Preview** in System Settings > Privacy & Security
> Accessibility. The scene forms around the icons within about 2 s, without a relaunch.

If the switch is enabled but the menu still shows **Grant Accessibility…** after a rebuild, macOS
may have retained permission for an older ad hoc signing hash. Reset that app's stale entry:

1. Quit **Deskland Preview** from its leaf menu.
2. Run `tccutil reset Accessibility app.deskland.preview.mac` in Terminal. This resets only this
   app's Accessibility permission.
3. Reopen the current app copy, for example `open ".capture/dist/Deskland Preview.app"` from the
   repository root, then choose **Grant Accessibility…** from its menu.
4. Reopen System Settings > Privacy & Security > Accessibility and enable **Deskland Preview**.
   If it is absent, use **+** to add the same app copy you just opened.

The reset removes the old permission; you must enable the current copy yourself. A later rebuild
can change its signing hash again.

Without the permission the host sends an empty icon list, so the page still shows its scene (open sea
on the Beach, drifting clouds on the Meadow), and it checks every 2 s whether access has been granted.

### What is read, and what never is

- Read: the **position and size** of each desktop icon (Finder's desktop, main screen only), and the
  position and size of on-screen windows (to decide when to pause).
- Never read: icon names, file names, paths, window titles or contents, or any other attribute. No
  action is ever performed on an icon. No network or desktop screenshots. The host writes preferences, the instance lock and short status
  lines in the system log (`deskland: …`). Optional desktop-preview matching saves only the
  rendered theme and a local wallpaper-restoration journal, as described below.

## How it talks to the pages

The pages were written for WebView2 on Windows. Loaded with `?wallpaper=1`, they look for
`window.chrome.webview`, add a `message` listener and post `'ready'`. A `WKUserScript` injected at
document start defines that object: `postMessage` goes to a `WKScriptMessageHandler`, and the host
delivers messages by calling `window.__desklandDeliver(text)`, which hands each listener
`{ data: "<json string>" }`, as WebView2 does.

After `ready` the host sends, in the same order as the Windows host:

1. `{"t":"settings","v":{…}}`: the theme's defaults from `themes.json`.
2. `{"t":"icons","vis":true,"r":[[left,top,right,bottom],…]}`: icon rects in physical pixels from
   the top left of the main screen (points × `backingScaleFactor`). Sent again only when they change
   (polled every 0.4 s, every 0.1 s for 2 s after a change).
3. `{"t":"pause","v":true|false}`.

## Why a custom URL scheme, not file URLs

The pages are served from the bundle over a private scheme, `deskland://app/<page>`
(`SceneHandler` in `Scene.swift`), because file URLs break the Beach:

- WebKit gives every `file://` document an opaque origin, so images from `assets/` are cross-origin
  and taint the canvas. `beach-palms.js` reads that canvas back with `getImageData`, which throws: the
  Beach drew **no palm trees** and threw an error on every frame.
- Those errors arrive as a bare `Script error.` with no file or line, which makes the pages hard
  to debug.

Under `deskland://app/` everything is one origin: sprites and the palm atlas load, WebGL2 works,
`themes.json` is readable, and errors keep their file and line. The handler serves only files inside
`Contents/Resources/prototype`.

## Files

| File | What it does |
| --- | --- |
| `main.swift` | Starts the wallpaper (one instance) or a developer self-test |
| `App.swift` | The wallpaper window, the menu bar item, pausing, quitting |
| `Strings.swift` | Menu text in Simplified Chinese or English (from `prototype/i18n/*.json` where it exists) |
| `Shim.swift` | The injected `window.chrome.webview` shim and its message handler |
| `Scene.swift` | Themes (pages, names, defaults from `themes.json`), the `deskland://` scheme handler, the web view |
| `Icons.swift` | Reads the desktop icon frames from Finder through Accessibility |
| `SelfTest.swift` | Developer self-tests |
| `Info.plist` | Bundle id `app.deskland.preview.mac`, menu bar only (`LSUIElement`) |

## Developer self-tests

For developers only: there is no menu item for them. They draw in a window placed off every screen,
show nothing, take no lock and do not need Accessibility, so they can run next to a running copy.

```sh
A=".capture/dist/Deskland Preview.app/Contents/MacOS/Deskland"
"$A" --selftest meadow out.png             # 9 fake icons; exit 0, or 1 on any JavaScript error
"$A" --selftest beach out.png --no-icons   # with an empty icon list
"$A" --selftest-shim                       # message flow: 'ready' first, every message in order
```

The scene test uses a 1728 × 1117 point web view at scale 2. It sends the settings, the icons and
`pause:false` once the page says `ready`, waits about 6.5 s, logs the page state (canvas size,
WebGL2, `cap30`, measured fps) and writes a snapshot PNG. A watchdog exits 1 if anything stalls.

## Local demo and profiling

Double-click `tools/demo-mac.command` in Finder, or run it from the repository. It builds the app
if needed and opens a normal window with sample icons; it does not require Accessibility.
The Demo menu switches themes (⌘1/⌘2), pauses (⌘P), moves sample icons (⌘M), and reloads (⌘R).
Close the window or use ⌘Q to quit. Launch the app without arguments for the actual wallpaper.

For shared-theme development, quit the wallpaper and run `tools/wallpaper-mac.command` (or
double-click it in Finder). It copies this checkout's `prototype/` assets into the app's own support
folder and points the existing host there through `DESKLAND_PAGES`, building only if the app is
missing. This lets the host read the theme assets without access to the source Documents folder.
Quit and rerun the launcher after editing themes; opening the app directly uses its bundled pages.
Theme-only edits do not rebuild or change the host's signature.
Swift host changes still require a build and may require the Accessibility reset described above.

```sh
tools/make-mac.sh
A=".capture/dist/Deskland Preview.app/Contents/MacOS/Deskland"
"$A" --demo beach
mkdir -p .capture/profiles
"$A" --profile meadow .capture/profiles/meadow.json
"$A" --profile beach .capture/profiles/beach.json --no-icons
python3 tools/profile-mac-resources.py .capture/profiles/resources.json -- \
  "$A" --profile meadow .capture/profiles/frames.json
tools/test-mac-policy.sh
node tools/tests/test_terrain_transitions.mjs
"$A" --selftest-demo .capture/demo-tests
```

The profile uses the main display's current logical dimensions and backing scale, a fixed seed,
and nine sample icon rectangles (or none). Actors and some noise remain randomized, so repeat
comparisons before attributing small CPU differences to a patch. After warmup it measures active, paused, and resumed
phases. JSON records rendered FPS, rAF callbacks, synchronous readbacks, frame callback duration
and frame interval distributions. Callback duration includes JavaScript and synchronous waits;
it does not measure asynchronous GPU execution or energy use. The profile is offscreen and does
not exercise Finder polling or desktop window coverage.

The optional Python sampler uses macOS process counters for host CPU time, wakeups and memory,
plus newly spawned WebKit processes. Keep other WebKit launches quiet during a run: attribution
uses creation time because XPC processes belong to launchd. CPU 100% means one full core; summed
physical footprints can count shared allocations twice. Reports remain under ignored `.capture/`.
Full Xcode/Instruments is optional for deeper GPU and energy profiling.

The demo integration test opens a temporary visible window, checks both themes, movement,
resize, pause/resume, reload and the existing share-snapshot bridge, saves images/JSON, then exits.
It does not move real Finder icons or change system permissions. Actual sleep/wake, Spaces,
Stage Manager, multiple displays and permission revocation still need interactive testing.

The host keeps only a message counter, checks icon permission and visibility every two seconds when paused,
and reads Finder positions once when icons reappear rather than continuously while paused.
It stops icon/window polling during sleep, lock, inactive-session or screen-saver suspension.
Independent suspension reasons prevent a display-wake event from clearing an active lock.
The theme pages skip hidden diagnostic GPU readbacks and DOM timers in wallpaper/preview mode;
explicit `__dbg.bench()` and ordinary browser diagnostics remain available.

## Hidden desktop icons and the new-desktop preview

When macOS hides desktop items after clicking the wallpaper, Finder may still expose their AX
rectangles. The host also checks the ordering of Finder and WindowManager desktop-icon windows,
using geometry and visibility metadata only. A hiding layer clears the icon rectangles sent to the
scene; revealing the icons restores them. Normal application windows only pause animation. Meadow
also redraws its static layout once when an icon update arrives while paused, matching Beach.
Natural drifting clouds and characters remain; the dense shapes tied to hidden icons disappear.

The leaf menu's **Match new desktop preview** option makes Mission Control's “+” thumbnail match
the selected scene. It is off by default. When enabled, the host snapshots only its WKWebView after
scene/layout changes have settled and uses the public desktop-picture API to update macOS. There
is no periodic screenshot loop. The thumbnail is a still frame; the wallpaper window stays animated.

The public API cannot preserve all original dynamic-wallpaper and Space settings by itself. Before
changing anything, the host saves a local recovery journal. On disable or normal quit it merges back
only settings still owned by its snapshots, preserving a wallpaper the user selected meanwhile.
New Spaces that inherited an app snapshot return to their underlying wallpaper settings too.
Exact restoration uses the versioned macOS wallpaper store format; unsupported or malformed state
stops syncing. Forced termination leaves recovery for the next launch. Snapshot files still referenced
by macOS are retained. This is an experimental integration, not a public all-Spaces wallpaper API.

Developer checks (no preference changes):

```sh
tools/test-mac-icon-visibility.sh
tools/test-mac-interaction.sh
tools/test-wallpaper-restore.sh
```

The native `--selftest-demo` checks hiding and revealing icon layouts while paused in both themes.
The Node transition checks exercise interrupted reveals, hides and repeated moves using the actual
field and texture-upload code. New targets start from the currently displayed blend. Pausing a
partly completed transition freezes it; new icon layouts received while paused still update once.
Both themes retain their original 1800 ms interactive transitions and 2600 ms opening. A passive
global left-mouse-up listener requests an immediate coverage and icon refresh, then rechecks at
50, 150 and 300 ms because Finder may publish a drop or visibility change after the release.
Each release replaces pending follow-ups; an in-flight Finder read completes before one queued
refresh, and unchanged layouts are not resent. Suspension and quit remove the listener and cancel
the burst. The listener does not consume clicks or retain event contents. Unrelated clicks can
also trigger this bounded work. Fallback icon polling remains at 0.1 seconds during recent changes
and 0.4 seconds when stable; paused visibility checks remain at two seconds.
For onset diagnostics, launch the host with `DESKLAND_TRACE_INTERACTIONS=1`. It logs each observed
mouse-up and elapsed time to the next changed icon layout, without event coordinates or file
details. This measures host notification timing, not when GPU pixels reach the display.

## Known gaps

- Main screen only, as on Windows: other displays keep their normal wallpaper.
- The settings page (`settings.html`) is not hosted yet: each theme runs with its defaults.
- Share (snapshot / recording) messages from the page are only logged.
- No start-at-login option yet.
- Unsigned (ad hoc): Gatekeeper asks on first open of a downloaded copy, and the Accessibility switch
  may need resetting after a rebuild.
- The pause rule looks at one window at a time; several windows that together cover the screen do
  not pause it (as on Windows).

---

## 中文说明

[English](#deskland-preview-for-macos-host) · **简体中文**

一个原生 macOS 小宿主，把 Deskland 的两个开源主题——草地（`prototype/meadow.html`）和沙滩
（`prototype/flat.html`）——作为动态桌面壁纸运行，场景会围绕真实的桌面图标生成。主题页面不做任何修改。
本目录相当于 Windows 宿主 `host/` 的 Mac 版，与仓库其他部分同样按 GPL-3.0 发布（见顶层 `LICENSE`、
`NOTICE`、`THIRD_PARTY_NOTICES.md` 和 `TRADEMARKS.md`）。

窗口、网页视图和辅助功能相关的部分代码改编自 Jeremy Day 的 Desk Critters，在此按 GPL-3.0 发布。

### 构建

```sh
tools/make-mac.sh            # 生成 ".capture/dist/Deskland Preview.app" 并输出路径
tools/make-mac.sh <目录>      # 或生成 "<目录>/Deskland Preview.app"
```

只需要 Xcode 命令行工具（`swiftc`）。生成通用二进制（Apple 芯片与 Intel，macOS 13 及以上），把
`prototype/` 复制到 `Contents/Resources/prototype`，版本号取自 `tools/version.json`，并做临时（ad hoc）签名。

### 运行

先退出其他动态壁纸，再打开 `Deskland Preview.app`。菜单栏出现一片叶子（不显示在程序坞）。菜单包括：
主题（草地 / 沙滩，会记住）、暂停动画、重新载入、授予辅助功能权限…（仅在未授权时显示）、关于，以及
退出（恢复原壁纸）。系统首选语言为中文时菜单显示简体中文，否则显示英文。

- 同时只运行一份，再次打开不会启动第二份。
- 退出（或注销、`kill`）时会移除壁纸窗口，立即恢复原来的桌面图片。
- 与其他 Deskland 版本身份独立：bundle id 为 `app.deskland.preview.mac`，设置保存在同名 UserDefaults
  域，单实例锁位于 `~/Library/Application Support/app.deskland.preview.mac/`。
- 当某个窗口几乎占满主屏幕（85% 以上，如缩放或全屏）、显示器睡眠、锁屏、屏幕保护程序运行，或勾选
  “暂停动画”时自动暂停。
- 帧率：页面自身限帧 30fps（`cap30`，默认开启）。宿主不额外加定时器或 display link 驱动画面，
  页面的 `requestAnimationFrame` 由 WebKit 照常调度。

### 辅助功能权限

Finder 只通过辅助功能告诉其他程序桌面图标的位置。在菜单中选择“授予辅助功能权限…”，或在 系统设置 >
隐私与安全性 > 辅助功能 中打开 **Deskland Preview**。约 2 秒内场景就会围绕图标生成，无需重启。

如果重新构建后开关已经启用，但菜单仍显示“授予辅助功能权限…”，macOS 可能仍将权限关联到旧的
临时签名哈希。可按以下步骤重置本应用的旧权限记录：

1. 从叶子菜单退出 **Deskland Preview**。
2. 在终端运行 `tccutil reset Accessibility app.deskland.preview.mac`。此命令仅重置本应用的辅助功能权限。
3. 重新打开当前应用副本，例如在仓库根目录运行 `open ".capture/dist/Deskland Preview.app"`，然后在应用
   菜单中选择“授予辅助功能权限…”。
4. 重新打开 系统设置 > 隐私与安全性 > 辅助功能，并启用 **Deskland Preview**。如果列表中没有该应用，
   用“+”添加刚刚打开的同一副本。

重置只会移除旧权限，仍需由你手动启用当前副本。再次构建可能再次改变签名哈希。

未授权时宿主发送空的图标列表，页面仍显示场景（沙滩为开阔海面，草地为漂浮的云），并每 2 秒检查一次是否已授权。

#### 读取什么，绝不读取什么

- 读取：每个桌面图标的**位置和大小**（Finder 桌面，仅主屏幕），以及屏幕上窗口的位置和大小（用于判断何时暂停）。
- 绝不读取：图标名称、文件名、路径、窗口标题或内容。不会对图标执行任何操作，不联网，也不截取桌面或其他应用。
  除设置、单实例锁和简短日志外，可选的桌面预览同步会保存主题渲染图及本地恢复记录。

### 与页面的通信

页面原为 Windows 上的 WebView2 编写。以 `?wallpaper=1` 加载时，页面查找 `window.chrome.webview`、
添加 `message` 监听并发送 `'ready'`。宿主在文档开始时注入一个 `WKUserScript` 提供这个对象：
`postMessage` 交给 `WKScriptMessageHandler`；宿主调用 `window.__desklandDeliver(text)` 发送消息，
每个监听器收到 `{ data: "<json 字符串>" }`，与 WebView2 一致。收到 `ready` 后按 Windows 宿主的顺序发送
`settings`（`themes.json` 中的默认值）、`icons`（主屏幕左上角起算的物理像素矩形，仅在变化时重发）和 `pause`。

### 为什么用自定义 URL scheme 而不是 file URL

页面通过私有 scheme `deskland://app/<页面>` 从程序包内提供，因为 file URL 会让沙滩出错：WebKit 给每个
`file://` 文档不透明的源，`assets/` 中的图片因此跨源并污染画布，`beach-palms.js` 用 `getImageData`
读回画布时抛出异常，沙滩**一棵椰子树都画不出**，且每帧报错；错误只显示为没有文件和行号的
`Script error.`，难以调试。在 `deskland://app/` 下所有资源同源，贴图和椰树图集正常加载，WebGL2 可用，
错误保留文件和行号。处理器只提供 `Contents/Resources/prototype` 内的文件。

### 开发者自测

仅供开发者使用，菜单中没有入口。自测在屏幕之外的窗口中绘制，不显示任何内容、不占用单实例锁、
不需要辅助功能权限，可与正在运行的壁纸同时进行。

```sh
A=".capture/dist/Deskland Preview.app/Contents/MacOS/Deskland"
"$A" --selftest meadow out.png             # 9 个模拟图标；成功退出码 0，有任何 JavaScript 错误则为 1
"$A" --selftest beach out.png --no-icons   # 空图标列表
"$A" --selftest-shim                       # 消息流：先收到 'ready'，所有消息按顺序送达
```

### 已知不足

- 与 Windows 版相同，仅支持主屏幕，其他显示器保持原壁纸。
- 尚未承载设置页（`settings.html`），每个主题使用默认参数。
- 页面发出的分享（图片 / 录制）消息只记录日志。
- 暂无登录时自动启动选项。
- 未正式签名（ad hoc）：下载的副本首次打开时 Gatekeeper 会提示，重新构建后可能需要重置辅助功能开关。
- 暂停规则逐个窗口判断，多个窗口合起来覆盖屏幕时不会暂停（与 Windows 版相同）。

### 本地演示与性能分析

双击 `tools/demo-mac.command` 可打开普通演示窗口，无需辅助功能权限。菜单支持切换主题（⌘1/⌘2）、
暂停（⌘P）、移动示例图标（⌘M）、重载（⌘R）和退出（⌘Q）。不带参数启动应用仍是桌面壁纸模式。

开发共享主题时，先退出壁纸，再运行或双击 `tools/wallpaper-mac.command`。它将仓库的 `prototype/`
资源复制到应用自己的支持目录，再通过 `DESKLAND_PAGES` 让现有宿主读取副本，仅在应用不存在时
构建。宿主无需读取“文稿”中的源目录。编辑主题后退出并重新运行脚本；直接打开应用仍读取包内
页面。只改主题无需重建或更改签名。
修改 Swift 宿主仍需构建，且可能需要按上文重置辅助功能权限。

`--profile <meadow|beach> <out.json> [--no-icons]` 按当前主屏幕逻辑尺寸与缩放比例，在屏幕外测量
运行、暂停及恢复后的帧数、rAF 回调、同步 GPU 读回和回调耗时；这不是 GPU 执行时间或能耗测量。
`tools/profile-mac-resources.py` 可同时采样宿主及新建 WebKit 进程的 CPU、唤醒和内存；运行期间
避免启动其他 WebKit 应用，累计内存可能重复计算共享分配。结果请保存在忽略的 `.capture/` 目录。

`tools/test-mac-policy.sh` 测试暂停原因叠加及轮询策略。`--selftest-demo <目录>` 会短暂打开窗口，
验证两主题的移动、缩放、暂停恢复、重载及分享图片消息并保存结果，然后退出。它不操作真实图标或
修改系统权限；实际休眠唤醒、空间、台前调度、多显示器及权限撤销仍需人工验证。

宿主仅保留消息计数，暂停时每两秒检查权限与可见性，图标重新显示时只读取一次 Finder 位置。
休眠、锁屏、会话停用或屏保期间停止轮询。
各暂停原因独立维护。壁纸与预览模式跳过隐藏诊断的 GPU 读回及 DOM 计时器，显式性能测试仍可使用。

### 隐藏桌面图标与新增桌面预览

macOS 隐藏桌面图标时，Finder 可能仍返回原来的位置。宿主检查 Finder 与 WindowManager 在
桌面图标层的前后关系，只读几何与可见性元数据。隐藏时清空主题中的图标布局，显示时恢复。
普通窗口遮挡只触发暂停；草地在暂停期间也会单次更新静态布局。自然飘动的云和角色仍然保留。
图标更新打断过渡时，从当前显示的中间形状继续；暂停会冻结正在过渡的形状，恢复时继续。
暂停期间收到新的图标布局仍会单次更新。`node tools/tests/test_terrain_transitions.mjs` 验证这些行为。
两个主题保留原来的 1800 毫秒交互过渡与 2600 毫秒开场。被动监听全局鼠标左键释放后立即检查
遮挡与图标，并在 50、150、300 毫秒补查 Finder 稍后发布的拖放或可见性变化。新的释放替换
待执行的补查；正在进行的 Finder 读取完成后立即处理一次合并请求，不重发未变化的布局。
休眠、锁屏等挂起状态以及退出时移除监听并取消补查。监听不拦截点击、不保存事件内容；其他
应用中的点击也可能触发这组有上限的检查。保留原来的 0.1/0.4 秒轮询和暂停时每两秒的可见性检查。
`tools/test-mac-interaction.sh` 验证补查合并、取消和生命周期。

叶子菜单中的“同步新建桌面预览”默认关闭；开启后以当前主题的静帧更新 Mission Control 的“+”预览。
仅在场景和布局变化稳定后捕获应用自己的网页，不持续截屏。关闭功能或正常退出时，通过本地恢复
记录还原仍归应用所有的壁纸设置，保留用户随后选择的新壁纸。继承了应用静帧的新空间也会恢复
原有壁纸继承关系。精确恢复依赖 macOS 壁纸配置格式；
状态不支持或损坏时停止同步，强制退出后在下次启动恢复。仍被系统引用的图片会保留。
