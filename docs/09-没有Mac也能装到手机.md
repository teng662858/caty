# 没有 Mac 也能装到手机 —— GitHub 编译 + Windows 签名

> **这条路是什么**：编译必须在 macOS 上做，而你没 Mac。
> 所以我们借用 **GitHub 免费提供的 macOS 机器**编译出**未签名 ipa**，
> 再在 **Windows 上用 Sideloadly** 拿你自己的 Apple ID 签名装进 iPhone。
>
> **全程免费**，不需要开发者账号（$99 那个不用买）。
>
> 代价要说清楚：① 每次改代码要"推送 → 等 5–8 分钟 → 下载 ipa → 重新签名安装"，
> 比有 Mac 慢得多；② 免费账号签的 App **7 天过期**，到期重跑一次签名即可（数据不丢）。

---

## 总览：整条链路

```
你的 Windows 电脑                     GitHub 的 macOS 机器              你的 iPhone
─────────────────                    ────────────────────              ──────────
git push  ─────────────────────▶  下载 NodeMobile（校验 sha256）
                                   生成 Xcode 工程（XcodeGen）
                                   xcodebuild 编译（不签名）
                                   打包成 Caty-unsigned.ipa
        ◀─────────────────────    作为 Artifact 供下载
下载 ipa
Sideloadly 用你的 Apple ID 签名  ─────────────────────────────────▶  安装 + 信任证书
```

---

## 第 1 步 · 有 GitHub 账号（3 分钟）

没有的话：打开 https://github.com/signup ，用邮箱注册（要收验证邮件）。
已有账号跳过。

> 建议顺手开启两步验证以外就不用管别的了；我们只需要一个**私有仓库**（别人看不到）。

---

## 第 2 步 · 把代码推上去（在 Windows 上，Git Bash 里逐段粘贴）

先登录（会给你一个 8 位验证码，浏览器里粘贴即可；全程回车用默认选项）：

```bash
gh auth login --web --git-protocol https
```

看到 `✓ Logged in as <你的用户名>` 就成了。然后建仓库并上传：

```bash
cd /d/Zcode/Catys
git init
git branch -M main
git config user.name "Caty"
git config user.email "caty@local"
git add -A
git commit -m "Caty: P2/P3 代码 + 云端编译"
gh repo create caty --private --source=. --push
```

最后一行会打印仓库地址，形如 `https://github.com/你的用户名/caty`。

✅ 验收：刷新那个网页，能看到 `ios/`、`docs/`、`.github/` 这些文件夹。
⛔ `gh: command not found` → 本机 `gh` 应该在，若真没有就装 https://cli.github.com/
⛔ 传上去的东西不含 `host-data/`、`fixtures/`、`dist/`（已 gitignore，里面可能有你的源与凭据）

---

## 第 3 步 · 让 GitHub 编译（推上去就自动开始了）

1. 打开 `https://github.com/你的用户名/caty/actions`
2. 上面应该已经有一条正在跑的 **iOS 未签名 ipa**（黄点转圈）。等 **5–8 分钟**。
3. 变成 **绿色 ✓** 后，点进这次运行，页面**拉到最底部**的 **Artifacts**：
   - **`Caty-unsigned-ipa`** ← 这就是我们要的（下载下来是个 zip，**解压出里面的 `.ipa`**）
   - `xcodebuild-log` ← 编译日志（失败时它最有价值）

✅ 验收：解压后得到一个约 60–100 MB 的 `Caty-unsigned.ipa`。

⛔ **红色 ✗ 怎么办**：点进失败的那次运行 → 点左边标红的步骤 → 把红色报错**原文整段**贴给我；
或者下载 `xcodebuild-log` 里的 `xcodebuild.log` 发我。**不用自己判断原因。**

---

## 第 4 步 · Windows 上签名安装（Sideloadly）

### 4.1 装两个软件

1. **iTunes**：https://www.apple.com/itunes/download/win64 （**官网版**，不是微软商店版）
   —— 只为装苹果的 USB 驱动，装完不用打开它。
2. **Sideloadly**：https://sideloadly.io （Windows 版，装完打开）

### 4.2 连接手机

1. 数据线连 iPhone，手机上弹「要信任此电脑吗」→ **信任**。
2. 手机上先开好开发者模式（**iOS 16 起必须**）：
   `设置 › 隐私与安全性 › 开发者模式` → 打开 → 按提示**重启手机**。

### 4.3 签名并安装

1. 打开 Sideloadly，顶部 **iDevice** 栏应该出现你的 iPhone（没出现就重插线／重开软件）。
2. 把第 3 步解压出来的 **`Caty-unsigned.ipa` 拖进 Sideloadly 窗口**（或点 ipa 图标选它）。
3. **Apple ID** 填你自己的 Apple ID（免费账号即可）。
4. 点 **Start**，弹出密码框 → 输入 Apple ID 密码。
   - 如果开了双重认证：会再要一个 6 位验证码（手机上收到的那串）。
5. 等进度跑完（1–2 分钟），手机桌面上会出现 **Caty** 图标。

### 4.4 信任证书（第一次必做）

手机上：`设置 › 通用 › VPN 与设备管理 › 开发者 App` → 点你的 Apple ID → **信任**。

✅ 验收：点开 Caty，能看到「源 / 诊断」两个 tab。

---

## 第 5 步 · 验证（这一步就是 M1/D2 闸门）

1. 打开 Caty → 点 **「诊断」** tab → 等 30–60 秒（第一次慢是正常的）。
2. 期望看到：🟢 **已就绪**、`Node v24.20.0`、`serverStarted → http://127.0.0.1:xxxxx`、
   日志里有 `[stub] node=v24.20.0 arch=arm64 WebAssembly=object fetch=function`。
3. 点 **「复制日志（已脱敏）」** → 把日志贴给我 + 截一张图。

**如果这一步通了**，说明整个项目最大的风险点（iOS 无 JIT 上跑 Node）已经过了。
**如果没通**，把报错原文贴给我，我们对着 `docs/08-P2操作卡.md` 第 6 节的表排。

---

## 第 6 步 · 7 天后过期怎么办

免费 Apple ID 签的 App **7 天**后打不开（图标变灰或点开就退）。**这不是坏了**：

- 重新打开 Sideloadly，重复第 4 步（**不用重新下载 ipa**，除非我改了代码）→ 数据不丢。
- 想省事可以装 **AltStore**（https://altstore.io）：它配合电脑上的 AltServer，
  手机和电脑在同一 Wi-Fi 时**自动续签**，不用每次插线。

---

## 常见报错（这条路线特有的）

| 现象 | 原因 | 怎么办 |
|---|---|---|
| Actions 是红色 ✗ | 代码有编译错误（正常，第一次都可能） | 贴报错原文给我，我改完你重新推一次 |
| Artifacts 里没有 ipa | 编译失败了 | 看同一次运行的 `xcodebuild-log` 或贴红色步骤给我 |
| Sideloadly 顶部没有设备 | iTunes 没装 / 线没插好 / 没点"信任" | 重装官网版 iTunes，换数据线或换 USB 口 |
| Sideloadly 报 `Please sign in with an app-specific password` | Apple ID 开了双重认证 | 在 https://appleid.apple.com 生成「App 专用密码」填进去；或直接输短信验证码 |
| 装上后图标点不开 / 一点就退 | 开发者模式没开 / 证书没信任 | 回第 4.2 与 4.4 |
| `Untrusted Developer` | 同上 | `设置 › 通用 › VPN 与设备管理` → 信任 |
| `This app can't be installed... maximum number of apps` | 免费账号同时最多 3 个自签 App | 删掉别的自签 App 再装 |
| 打开后**立刻闪退**，日志里有 `dyld` / `code signature` | 嵌套的 NodeMobile 没被正确重签（自签常见坑） | 把原文发我；备选是改用 AltStore 安装 |
| 用了几天突然打不开 | 7 天到期 | 重跑一次 Sideloadly |

---

## 额度与注意事项

- **GitHub Actions 免费额度**：私有仓库每月 2000 分钟，**macOS 按 10 倍计** → 约 **200 分钟**
  ≈ **20–30 次编译**。够用，但**别频繁推送**（每次推送都会跑一次）。
  额度用完等到下月 1 号重置；或临时把仓库改成 Public（**不建议** —— 见下）。
- **为什么用私有仓库**：这个 App 是自签自用的容器，公开发布代码等于分发，和我们的合规边界不符。
- **仓库里不要放**：你的订阅地址、`host-data/`、`fixtures/`（已 gitignore）。
- 编译出来的 ipa 里**不含任何内容源**，源是运行时由你自己导入的。
