# dsh-plugin-update

从 DSH **外部**更新第三方插件，绕开市场里那个「正在被占用」。

Windows · PowerShell 7+ · 无需额外安装任何东西（复用 DSH 自带的 node 与 pnpm）

---

## 这个脚本是怎么来的

这是一个被气出来的工具。

我在 DeepSeek Harness 的插件市场里更新插件，每次都收到同一句提示：

> **文件正被打开着，这一步没有换上。市场启动就会再占用这些文件，再点更新也换不上。**

一开始我以为是偶发的文件锁，关掉 DSH 重开、再点一次。还是这句。换插件、换顺序、清缓存、重装市场——全都没用。它稳定复现，像一堵墙。

去翻 `dshmarket` 的源码才发现，这不是 bug，而是**结构性不可能**：

- DSH 运行时会把插件 JS `require` 进自己的进程
- Windows 上，被 `require` 的文件持有句柄，其他进程无法替换
- pnpm 换版本的方式，是把新目录 `rename` 到旧目录上
- 旧目录里还有被占用的文件 → `rename` 被系统拒绝 → `EPERM`

也就是说：**只要 DSH 开着，市场里的「更新」按钮就永远点不成功**。市场自己也提示了要退出 DSH 再手动跑 `pnpm add`，但那意味着你得自己记包名、自己拼版本号、自己处理 workspace 的 `-w`、自己对付 pnpm 的新版本冷静期……

更麻烦的是，pnpm 在改名重试之前会**尽量清空目标目录**。所以反复点那个按钮，有可能把一个插件弄成半残——源码里甚至有逻辑会在严重失败时把插件从 `package.json` 和 `dsh.profile.bundles` 里直接移除。

于是就有了这个脚本：把这些手动步骤全部自动化，只做一件事——**在 DSH 完全退出之后，从外面把插件更新掉**。

---

## 它解决的具体问题

| 手动做的麻烦事 | 脚本怎么处理 |
| --- | --- |
| 得自己查每个插件的最新版 | 直连 npm registry 比对 `dist-tags` |
| 得自己读 `engines.dsh` 判断兼不兼容 | 自动解析 semver 范围，标出不兼容的 |
| 得记得加 `-w`，否则 `ERR_PNPM_ADDING_TO_ROOT` | 自动检测 `pnpm-workspace.yaml` 并注入 |
| 新发布的版本装不上（pnpm 默认等 1 天） | 自动带 `--config.minimum-release-age=0` |
| 忘了只退 DSH、终端其实是 DSH 的子进程 | 预检进程 + 警告不要用 DSH 内置终端 |
| 装完不知道到底成没成 | 核对 `package.json` 与 `node_modules` 两边版本 |
| 万一装坏了没法回退 | 装之前自动备份三个清单文件 |
| 跨盘跑 pnpm 会另建 store | 始终在 profile 目录（通常在 C 盘）里执行 |

---

## 前置条件

- **Windows**
- **PowerShell 7.0+**（`pwsh.exe`）。查看版本：`pwsh -v`。没有的话去 [aka.ms/powershell](https://aka.ms/powershell) 装一个。系统自带的 5.1 **跑不了**，脚本第一行就是 `#Requires -Version 7.0`。
- 一个装好的 DSH。脚本会自己找 DSH 的 node 与 pnpm，不用你装 Node.js。

## 用法

### 1. 完全退出 DSH

关窗口**不算**。托盘图标右键退出。任务管理器里不应该再看到 `DeepSeek Harness`。

> 脚本会检查这一点。如果它说「检测到 DSH 正在运行」，就说明还有残留进程。

### 2. 打开一个独立的 PowerShell 窗口

开始菜单搜 `PowerShell` 打开就行。

> ⚠️ **不要用 DSH 内置的终端**。那是 DSH 的子进程，DSH 一关它就跟着被杀，更新会中断在半路。

### 3. 运行

```powershell
cd "路径\到\dsh-plugin-update"
pwsh -File .\Update-DshPlugins.ps1
```

或者直接双击 `update.cmd`。

---

## 常用跑法

```powershell
# 先看看有什么可更新，不装任何东西（DSH 开着也能跑）
pwsh -File .\Update-DshPlugins.ps1 -Check

# 更新所有可更新项（默认）
pwsh -File .\Update-DshPlugins.ps1

# 只更新指定的几个
pwsh -File .\Update-DshPlugins.ps1 -Only dsh-free-search,dshmarket

# 看看会执行什么命令，不真的装
pwsh -File .\Update-DshPlugins.ps1 -DryRun

# 一次性装完（快，但一个失败则整批失败）
pwsh -File .\Update-DshPlugins.ps1 -Batch

# 装预发布版
pwsh -File .\Update-DshPlugins.ps1 -Tag beta

# 整份退回某个备份
pwsh -File .\Update-DshPlugins.ps1 -RollbackFrom .\_backups\profile-20261121-094129
```

## 参数

| 参数 | 说明 |
| --- | --- |
| `-Profile <名>` | 目标 profile，默认 `desktop` |
| `-ProfileDir <路径>` | 直接指定 profile 目录，给了就忽略 `-Profile` |
| `-Only <包名...>` | 只处理这些包，支持 `*` 通配 |
| `-Check` | 只检查，不安装 |
| `-DryRun` | 打印命令，不产生写入 |
| `-Batch` | 合并成一次 `pnpm add` |
| `-Tag <tag>` | npm dist-tag，默认 `latest` |
| `-AllowIncompatible` | `engines.dsh` 不满足也照装 |
| `-IncludeGit` | 连 `github:` 依赖一起重新解析 |
| `-Force` | 跳过 DSH 运行检查（不建议） |
| `-NoBackup` | 不备份清单文件 |
| `-RollbackFrom <目录>` | 从备份恢复 |
| `-NodeExe` / `-PnpmScript` | 手动指定 node / pnpm 路径 |

---

## 它做了什么

| 阶段 | 行为 |
| --- | --- |
| 预检 | 定位 DSH 自带的 node/pnpm；确认 `DeepSeek Harness` 进程已退出 |
| 查新 | `check-updates.mjs` 直连 npm registry，比对 `dist-tags`，读 `engines.dsh` 判兼容 |
| 备份 | 三个清单文件复制到 `_backups\profile-<时间戳>\` |
| 安装 | 在 profile 目录执行 `pnpm add -w --save-exact --config.minimum-release-age=0 <包>@<版本>` |
| 校验 | 核对 `package.json` 与 `node_modules` 两边版本 |
| 汇总 | 成功/失败清单、失败原因、回滚命令、日志路径 |

几个关键设计：

- **`-w`** —— profile 里有 `pnpm-workspace.yaml`，pnpm 9+ 把它当 workspace root，不加 `-w` 会报 `ERR_PNPM_ADDING_TO_ROOT`。
- **`--config.minimum-release-age=0`** —— pnpm 默认对新版本有 1440 分钟的「冷静期」，刚发布的装不上。市场内部也带了这个参数。
- **`--save-exact`** —— 与市场写法一致，`package.json` 里记精确版本而不是 `^x.y.z`。
- **逐包安装**（默认）—— 某个插件失败不连累其它。

## 它不做什么

- **不碰 `dsh.profile.bundles`** —— 那个数组只决定加载哪些插件、什么顺序，更新版本不需要动它。
- **不处理 `github:` 依赖** —— 像 `github:user/repo#<sha>` 这种锁定到 commit 的没有「最新版本」概念。要更新得自己改 sha，或用 `-IncludeGit` 按分支 HEAD 重新解析。
- **不启动 DSH** —— 装完你自己开。

---

## 出问题怎么办

**报 EPERM / 「正在被占用」**

还有 DSH 相关进程没退干净。任务管理器里检查 `DeepSeek Harness`、`electron`、`node`。

注意：有些 `electron.exe` 是浏览器工具之类的辅助进程，**不加载插件**，脚本会把它们单独列为「可以留」，不会拦你。

**某个插件更新后 DSH 起不来**

用汇总里打印的 `-RollbackFrom` 命令整体退回。回滚会恢复三个文件并重装依赖；如果发现 `node_modules` 里的版本没真的换回来，会自动再跑一次 `--force` 重新链接。

**想彻底重来**

删掉 profile 下的 `node_modules`，然后：

```powershell
pwsh -File .\Update-DshPlugins.ps1 -RollbackFrom .\_backups\<最新的那个>
```

**找不到 DSH 的 node/pnpm**

脚本会依次尝试：环境变量 → 运行中的进程路径 → `PATH` 上的 `dsh.cmd` → 卸载登记表 → 常见安装位置。都失败时手动指定：

```powershell
pwsh -File .\Update-DshPlugins.ps1 `
  -NodeExe 'D:\APP\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe' `
  -PnpmScript 'D:\APP\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\pnpm\dist\pnpm.mjs'
```

---

## 文件

| 文件 | 作用 |
| --- | --- |
| `Update-DshPlugins.ps1` | 主脚本 |
| `check-updates.mjs` | 查版本；也可单独用：`node check-updates.mjs <profileDir> --dsh <版本>` |
| `update.cmd` | 双击入口 |
| `logs\` | 每次运行的完整日志（自动生成，已在 `.gitignore`） |
| `_backups\` | 更新前的文件备份（自动生成，已在 `.gitignore`） |

## 只查版本不装东西

`check-updates.mjs` 可以独立运行，输出一行 JSON：

```powershell
node .\check-updates.mjs "$env:USERPROFILE\.dsh\profiles\desktop" --dsh 0.2.2-rc.5
```

它的职责很单纯：读 `package.json`，对每个 npm 依赖查 registry，返回当前版本、最新版本、是否兼容、包体积。纯只读，不写任何文件。

---

## 已验证

在真实 profile（DSH 0.2.2-rc.5，19 个第三方依赖）上跑过：

- 单包更新 `dsh-unlag` 1.17.5 → 1.17.10，22.9s，校验通过
- 全量更新 7 个包，全部成功，其中 `dsh-univer-office` 0.4.0 → 0.5.0（160 MB）38s
- `-Check`、`-DryRun`、`-Only`、`-Batch`、错误 dist-tag、不存在的包名、回滚路径都走过

## 许可证

MIT
