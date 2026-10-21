# DSH 插件更新工具

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)](#环境要求)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D4?logo=windows&logoColor=white)](#环境要求)
[![GitHub stars](https://img.shields.io/github/stars/Crystalpiny/dsh-plugin-update?style=flat)](https://github.com/Crystalpiny/dsh-plugin-update)
[![GitHub release](https://img.shields.io/github/v/release/Crystalpiny/dsh-plugin-update?style=flat)](https://github.com/Crystalpiny/dsh-plugin-update/releases)

一个 PowerShell 脚本，把 DSH（DeepSeek Harness）桌面版 profile 里的第三方插件批量升到 npm 上的最新版本。更新前自动备份，出问题可以一键回滚。

> 非官方社区工具，与 DeepSeek 官方无关。安装仍然走 DSH 自带的 `dsh plugin`，不绕过官方的版本兼容性检查。

## 为什么需要它

在桌面端的插件市场里点“更新”时，正在加载的插件会被判定为 `bundle-in-use`（插件正在使用中），更新经常半途失败。

这个脚本改为在 DSH 完全退出后运行：

- 没有“正在使用”的限制，包括当前已启用插件在内的所有第三方插件都能一次更新完
- 更新前把 profile 的清单和锁文件备份好
- 单个插件失败不影响已经成功的部分，随时可以回滚

## 特性

- 复用官方安装链路：`dsh plugin add`、桌面端内置的 pnpm、安装前的版本兼容性预检
- 更新前自动备份 `package.json`、`pnpm-lock.yaml`、`pnpm-workspace.yaml`
- `-Check` 只读检查、`-DryRun` 预演、`-Only` / `-Skip` 精确选择插件
- 失败继续（`-ContinueOnError`）、一键回滚（`-Restore`）
- 保留原来的版本号写法（精确版本、`^`、`~`），只改 `dependencies`
- 支持多个 profile（`-AllProfiles`）和 Windows PowerShell 5.1 / PowerShell 7

## 环境要求

- Windows 10 / 11
- PowerShell 5.1 或 PowerShell 7+（`Update-DshPlugins.cmd` 会优先使用 `pwsh`）
- 安装过 DSH 桌面版，并至少启动过一次，使 `%USERPROFILE%\.dsh\profiles\desktop\package.json` 存在

## 安装

```powershell
git clone https://github.com/Crystalpiny/dsh-plugin-update.git
cd dsh-plugin-update
```

不想用 git 的话，到 [Releases](https://github.com/Crystalpiny/dsh-plugin-update/releases) 下载源码包解压即可。从浏览器下载的脚本会被 Windows 标记为“来自 Internet”，首次运行前解除锁定：

```powershell
Unblock-File .\Update-DshPlugins.ps1
```

如果直接运行 `.ps1` 被 ExecutionPolicy 拦住，用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-DshPlugins.ps1 -Check
```

或者双击 `Update-DshPlugins.cmd`，它已经带了 `-ExecutionPolicy Bypass`。

## 快速开始

```powershell
# 1. 先看哪些插件能更新（DSH 开着也能跑）
.\Update-DshPlugins.ps1 -Check

# 2. 从托盘菜单完全退出 DeepSeek Harness

# 3. 更新全部插件
.\Update-DshPlugins.ps1

# 4. 重新打开 DeepSeek Harness
```

> 为什么更新前必须退出 DSH：桌面端运行时会持有 `profiles\desktop\package.json.lock` 写入锁，
> 已加载的插件 bundle 也会被判定为 in use / bundle-in-use 而拒绝替换。真正写文件的操作只能在
> 没有 DSH 进程时进行；只读的 `-Check` / `-DryRun` 不受影响。

## 常用用法

```powershell
# 只看不更新
.\Update-DshPlugins.ps1 -Check

# 显示将执行的 dsh 命令，不做任何修改
.\Update-DshPlugins.ps1 -DryRun

# 只更新两个插件，不再询问
.\Update-DshPlugins.ps1 -Only dsh-claude-style,dsh-context -Yes

# 跳过某个插件
.\Update-DshPlugins.ps1 -Skip dshmarket

# 某个失败也继续更新其余插件
.\Update-DshPlugins.ps1 -ContinueOnError

# 更新所有 profile（desktop、web、自定义 profile）
.\Update-DshPlugins.ps1 -AllProfiles

# 更新完自动启动 DSH
.\Update-DshPlugins.ps1 -Restart

# 回滚到某次备份（备份在 profile 目录下的 .plugin-updates；也可传该目录，自动取最新一份）
.\Update-DshPlugins.ps1 -Restore "$env:USERPROFILE\.dsh\profiles\desktop\.plugin-updates\desktop-20261021-221500"
```

## 参数

| 参数 | 说明 |
| --- | --- |
| `-ProfileName <name>` | 要处理的 profile，默认 `desktop` |
| `-AllProfiles` | 处理 `%DSH_HOME%\profiles`（默认 `%USERPROFILE%\.dsh\profiles`）下所有已初始化的 profile |
| `-Check` | 只检查、列出版本，不写入（DSH 运行中可用） |
| `-DryRun` | 只打印将执行的命令（DSH 运行中可用） |
| `-Yes` | 不询问确认 |
| `-Force` | 跳过“DSH 正在运行”的进程检查（仅用于误报；写入锁被占用时仍会拒绝） |
| `-Only <patterns>` | 只处理匹配的插件，支持通配符 |
| `-Skip <patterns>` | 跳过匹配的插件，支持通配符 |
| `-DshCli <path>` | 指定 `dsh.cmd`；默认自动查找 |
| `-Registry <url>` | 查询最新版本用的 registry；默认读 `.npmrc`，否则 npmjs |
| `-NoBackup` | 不备份（不建议） |
| `-ContinueOnError` | 单个插件失败后继续 |
| `-IncludeOfficial` | 也更新 `@deepseek-ai/*` 官方运行时包（默认跳过） |
| `-Restart` | 更新完成后启动 DSH |
| `-Restore <dir>` | 回滚到备份并重新安装 |

退出码：`0` 成功 / 无更新，`1` 有插件更新失败，`2` 前置检查未通过（DSH 在运行、找不到 CLI、profile 不存在等）。

## 输出示例

```text
  DSH 插件更新工具
  ==================================================================
  DSH 主目录 : C:\Users\you\.dsh
  操作模式   : 检查（只读）
  DSH CLI    : C:\Program Files\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd
  DSH 版本   : 0.2.1-rc.2

----------------------------------------------------------------------
  profile: desktop
  目录     : C:\Users\you\.dsh\profiles\desktop
  [注意] DSH 桌面端正在运行（PID 9996）
  [注意] 配置写入锁被 PID 26156（DeepSeek Harness）占用
  registry : https://registry.npmjs.org

  插件                                     当前        最新        状态
  -----------------------------------------------------------------------
  dsh-claude-style                         0.16.2      0.18.1      可更新
  dsh-context                              0.73.1      0.74.0      可更新
  dsh-free-search                          0.9.5       0.9.11      可更新
  dsh-ops                                  0.4.0       0.4.1       可更新
  dshmarket                                1.66.35     1.66.45     可更新

  可更新 5 个，已是最新 5 个，跳过 0 个。
```

示例中的版本号会随时间变化，以 registry 上的实际结果为准。

## 工作原理

1. 读取 `%DSH_HOME%\profiles\<profile>\package.json` 的 `dependencies`（`DSH_HOME` 默认 `%USERPROFILE%\.dsh`）。
2. 用 HTTP 向 registry 查询每个包的 `latest` 版本，与 `node_modules` 里实际安装的版本比较。
3. 对每个需要更新的包执行：

   ```
   dsh plugin --profile desktop add <包名>@<最新版本> --save-exact
   ```

   `dsh plugin` 会调用桌面端自带的 pnpm，并在安装前做插件与 DSH 运行时的兼容性预检；
   不兼容的版本会直接拒绝安装，而不是装完再坏。
4. 更新前把 profile 的三个文件备份到 `.plugin-updates\<profile>-<时间>`。
5. 更新后逐个读取 `node_modules` 复核安装版本，最后提示重启。

脚本只改 profile 的 `dependencies`，不会动 `dsh.profile.bundles` 的顺序，也不会升级 DSH 本体
（`@deepseek-ai/dsh-base` 等官方包随桌面端发布，默认跳过）。

## 安全与回滚

- **备份**：每次更新前自动备份到 profile 目录下的 `.plugin-updates\<profile>-<时间>`，路径会打印在输出里。
- **回滚**：`.\Update-DshPlugins.ps1 -Restore "<备份目录>"`，会把三个文件还原并重新安装；
  如果 pnpm 以“已是最新”为由不肯降级，脚本会自动再做一次 `install --force` 并复核版本。
- **兼容性**：由 DSH 自己的预检负责。被拒绝时输出里会出现
  `dsh: to accept the risk, run: dsh plugin --profile desktop allow-version ...`，
  脚本不会替你接受风险；确认要装再加 `--accept-risk` 授权。
- **供应链**：pnpm 11 的 `minimumReleaseAge` 策略仍然生效，脚本按 registry 的 `latest` 指定版本，
  pnpm 会把该版本写进 `pnpm-workspace.yaml` 的 `minimumReleaseAgeExclude`。

## 与插件市场里的更新按钮的区别

桌面端插件市场更新时，正在加载的插件会报 `bundle-in-use`（插件正在使用中）而失败。
本脚本在 DSH 完全退出后运行，不存在“正在使用”的限制，因此可以一次把包括当前已启用插件在内的
所有第三方插件更新完。两者共用同一套 `dsh plugin` 安装与兼容性检查，结果一致。

## 常见问题

### 提示“DSH 桌面端正在运行”

从托盘图标右键退出 DeepSeek Harness（只关窗口可能只是最小化到托盘），确认任务管理器里没有
`DeepSeek Harness.exe` 再运行。

### 提示“配置写入锁被活动进程占用”

说明还有 DSH 进程或上一次插件操作没结束。等一会儿再试，或在任务管理器里结束对应的
`DeepSeek Harness.exe` / `pnpm` 进程。该锁由 DSH 进程持有，进程退出后 dsh 会自动接管遗留的锁文件，
不需要手动删除；`-Force` 也无法绕过仍在生效的锁。

### 某个插件提示不兼容（incompatible）

新版本要求的 DSH 版本高于当前运行时。等 DSH 本体升级，或按输出里的 `allow-version` 命令显式授权。
脚本会把该插件记为失败，其余插件继续（加 `-ContinueOnError`）或停下，可用 `-Restore` 回滚。

### 找不到 dsh CLI

用 `-DshCli "<安装目录>\resources\runtime\cli\bin\dsh.cmd"` 指定。便携版、绿色版建议直接指定。

### 公司网络 / 镜像源

脚本读取 profile、`%DSH_HOME%`、用户目录下的 `.npmrc` 的 `registry=`；也可以
`-Registry https://registry.npmmirror.com`。注意镜像可能比官方源晚几小时，显示的“最新”会随之不同。

### 更新后想立刻生效

重启 DeepSeek Harness。客户端插件由桌面端加载，进程内的旧代码不会热替换。

### 脚本会升级 DSH 本体吗

不会。脚本只处理 profile 的 `dependencies`，`@deepseek-ai/*` 官方包默认跳过。

### 支持 macOS / Linux 吗

目前只支持 Windows。脚本依赖 Windows 的进程检测、注册表查找和 `%USERPROFILE%\.dsh` 目录布局。

## English

**DSH Plugin Updater** is a Windows PowerShell script that batch-updates third-party plugins in a DeepSeek Harness profile through the official `dsh plugin` CLI.

It backs up `package.json`, `pnpm-lock.yaml`, and `pnpm-workspace.yaml` before writing, supports check-only (`-Check`), dry-run (`-DryRun`), selective updates (`-Only` / `-Skip`), and restore (`-Restore`). Quit DeepSeek Harness before updating; `-Check` and `-DryRun` are safe while it runs. Requires Windows, PowerShell 5.1 or 7+, and an initialized DSH profile. MIT licensed. This is an unofficial community tool and is not affiliated with DeepSeek.

## 贡献

欢迎提 Issue 和 Pull Request。改动脚本后，请至少运行一次语法检查和 `-Check` / `-DryRun`。

## 许可证

[MIT](LICENSE) © 2026 Beluga

## 免责声明

本项目按“现状”提供，不附带任何担保。脚本会修改本机 DSH profile 的插件版本，请先用 `-Check` / `-DryRun` 确认影响范围，重要环境建议额外备份整个 profile 目录。因使用本脚本造成的插件不兼容、数据丢失或其他损失，由使用者自行承担。
