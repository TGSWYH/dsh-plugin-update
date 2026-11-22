#Requires -Version 7.0
<#
.SYNOPSIS
  在 DSH 完全退出后，从外部更新 DSH profile 里的第三方插件。
  用来绕开「正在被占用」：DSH 运行时会 require 插件的 JS，Windows 上文件句柄被占，
  pnpm 无法 rename/替换插件目录，于是市场里的「更新」必然失败。

.DESCRIPTION
  流程：预检 DSH 进程 → 查最新版（调同目录的 check-updates.mjs）→ 备份 manifest/lock
  → 在 profile 目录执行 `pnpm add -w --save-exact <pkg>@<ver>` → 校验 → 汇总。

  必须在 DSH 退出后、且在一个「不会被 DSH 一起关掉」的普通终端窗口里运行。
  从 DSH 自己的终端里启动的 PowerShell 是 DSH 的子进程，DSH 一关它就被杀，没法完成更新。

.PARAMETER Profile
  profile 名，默认 desktop（对应 %USERPROFILE%\.dsh\profiles\desktop）。

.PARAMETER ProfileDir
  直接指定 profile 目录，给了就忽略 -Profile。

.PARAMETER Only
  只处理这些包（可写多个，支持 * 通配）。默认处理全部可更新项。

.PARAMETER Check
  只检查有没有新版本，不安装。

.PARAMETER DryRun
  打印将要执行的命令，不产生任何写入。

.PARAMETER Batch
  把所有要更新的包合并成一次 pnpm add（更快，但一个失败则整批失败）。默认逐个更新。

.PARAMETER Tag
  npm dist-tag，默认 latest。

.PARAMETER AllowIncompatible
  engines.dsh 不满足当前 DSH 版本时也照装（默认跳过并提示）。

.PARAMETER IncludeGit
  连 github:/git: 依赖一起尝试（按分支/HEAD 重新解析）。默认跳过。

.PARAMETER Force
  跳过「DSH 是否在运行」的检查（不建议，多半会撞 EPERM）。

.PARAMETER NoBackup
  不备份 package.json / pnpm-lock.yaml。

.PARAMETER RollbackFrom
  从某个备份目录恢复三个文件并重装依赖，然后退出。

.EXAMPLE
  pwsh -File .\Update-DshPlugins.ps1 -Check

.EXAMPLE
  pwsh -File .\Update-DshPlugins.ps1

.EXAMPLE
  pwsh -File .\Update-DshPlugins.ps1 -Only dsh-free-search,dshmarket

.EXAMPLE
  pwsh -File .\Update-DshPlugins.ps1 -RollbackFrom .\_backups\profile-20261121-090000
#>
[CmdletBinding()]
param(
  [string]$Profile = 'desktop',
  [string]$ProfileDir,
  [string[]]$Only = @(),
  [switch]$Check,
  [switch]$DryRun,
  [switch]$Batch,
  [string]$Tag = 'latest',
  [switch]$AllowIncompatible,
  [switch]$IncludeGit,
  [switch]$Force,
  [switch]$NoBackup,
  [string]$RollbackFrom,
  [string]$NodeExe,
  [string]$PnpmScript
)

$ErrorActionPreference = 'Stop'

# ---------- 输出 ----------
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
try { $OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$script:LogPath = $null
function Write-LogLine([string]$text) {
  if ($script:LogPath) {
    try { Add-Content -LiteralPath $script:LogPath -Value $text -Encoding utf8 } catch { }
  }
}
function Write-Head([string]$t) {
  Write-Host ''
  Write-Host "== $t " -ForegroundColor Cyan -NoNewline
  Write-Host ('=' * [Math]::Max(2, 66 - $t.Length)) -ForegroundColor DarkCyan
  Write-LogLine "== $t"
}
function Write-Ok([string]$t)   { Write-Host "  [OK]   $t" -ForegroundColor Green;  Write-LogLine "[OK] $t" }
function Write-Info([string]$t) { Write-Host "  [..]   $t" -ForegroundColor Gray;   Write-LogLine "[..] $t" }
function Write-Warn([string]$t) { Write-Host "  [WARN] $t" -ForegroundColor Yellow; Write-LogLine "[WARN] $t" }
function Write-Err([string]$t)  { Write-Host "  [FAIL] $t" -ForegroundColor Red;    Write-LogLine "[FAIL] $t" }
function Write-Fatal([string]$t) {
  Write-Host ''
  Write-Host "错误: $t" -ForegroundColor Red
  Write-LogLine "FATAL $t"
  exit 1
}

# ---------- 定位 ----------
function Get-DshHome {
  if ($env:DSH_HOME -and $env:DSH_HOME.Trim()) { return $env:DSH_HOME.Trim() }
  return (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh')
}

function Resolve-ProfileDir {
  if ($ProfileDir) {
    if (-not (Test-Path -LiteralPath $ProfileDir)) { Write-Fatal "profile 目录不存在: $ProfileDir" }
    return (Resolve-Path -LiteralPath $ProfileDir).Path
  }
  $p = Join-Path (Get-DshHome) (Join-Path 'profiles' $Profile)
  if (-not (Test-Path -LiteralPath $p)) {
    $have = @()
    $root = Join-Path (Get-DshHome) 'profiles'
    if (Test-Path -LiteralPath $root) { $have = @(Get-ChildItem -LiteralPath $root -Directory | ForEach-Object { $_.Name }) }
    Write-Fatal ("找不到 profile 目录: $p`n可用 profile: " + (($have | Sort-Object) -join ', '))
  }
  return (Resolve-Path -LiteralPath $p).Path
}

# 从 "X:\...\resources\..." 这种路径里取出安装根 X:\...\
function Get-RootFromResourcesPath([string]$p) {
  if (-not $p) { return $null }
  if ($p -match '(?i)^(.*?)[\\/]resources[\\/]') { return $matches[1] }
  return $null
}

function Test-RuntimeRoot([string]$root) {
  if (-not $root) { return $null }
  $node = Join-Path $root 'resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
  $pnpm = Join-Path $root 'resources\runtime\primary-runtime\dependencies\pnpm\dist\pnpm.mjs'
  if ((Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $pnpm)) {
    return [pscustomobject]@{
      NodeExe    = $node
      PnpmScript = $pnpm
      DshCmd     = (Join-Path $root 'resources\runtime\cli\bin\dsh.cmd')
      Source     = $root
    }
  }
  return $null
}

function Resolve-Tools {
  $roots = New-Object System.Collections.Generic.List[string]
  foreach ($v in @($env:DSH_NODE_EXECUTABLE, $env:DSH_INSTALL_DIR, $env:DSH_ROOT)) {
    $r = Get-RootFromResourcesPath $v
    if ($r) { $roots.Add($r) }
  }
  # 正在跑的 DSH 的 exe 路径
  foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'DeepSeek Harness*' })) {
    try { $r = Get-RootFromResourcesPath $p.Path; if ($r) { $roots.Add($r) } } catch { }
  }
  # PATH 上的 dsh.cmd
  $cmd = Get-Command dsh.cmd -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { $r = Get-RootFromResourcesPath $cmd.Source; if ($r) { $roots.Add($r) } }
  # 卸载登记表
  $keys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($k in $keys) {
    try {
      Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*DeepSeek Harness*' -and $_.InstallLocation } |
        ForEach-Object { $roots.Add(($_.InstallLocation -replace '[\\/]+$', '')) }
    } catch { }
  }
  # 常见安装位置
  if ($env:LOCALAPPDATA) { $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness')) }
  if ($env:ProgramFiles) { $roots.Add((Join-Path $env:ProgramFiles 'DeepSeek Harness')) }
  if (${env:ProgramFiles(x86)}) { $roots.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')) }

  foreach ($r in ($roots | Select-Object -Unique)) {
    $hit = Test-RuntimeRoot $r
    if ($hit) { return $hit }
  }

  # 退路：显式参数 / .dsh\dsh-runtimes 里的副本 + 系统 node
  if ($NodeExe -and $PnpmScript -and (Test-Path -LiteralPath $NodeExe) -and (Test-Path -LiteralPath $PnpmScript)) {
    return [pscustomobject]@{ NodeExe = $NodeExe; PnpmScript = $PnpmScript; DshCmd = $null; Source = '(手动指定)' }
  }
  $fallbackPnpm = $null
  $rtRoot = Join-Path (Get-DshHome) 'dsh-runtimes'
  if (Test-Path -LiteralPath $rtRoot) {
    $fallbackPnpm = @(Get-ChildItem -LiteralPath $rtRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName 'dependencies\pnpm\dist\pnpm.mjs' } |
      Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
  }
  $sysNode = $null
  $nc = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($nc -and $nc.Source) { $sysNode = $nc.Source }
  if ($sysNode -and $fallbackPnpm) {
    return [pscustomobject]@{ NodeExe = $sysNode; PnpmScript = $fallbackPnpm; DshCmd = $null; Source = "(系统 node + $fallbackPnpm)" }
  }
  Write-Fatal ("找不到 DSH 自带的 node/pnpm。`n请用 -NodeExe 和 -PnpmScript 手动指定，例如：`n  -NodeExe 'D:\APP\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe' `n  -PnpmScript 'D:\APP\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\pnpm\dist\pnpm.mjs'")
}

function Get-DshProcesses {
  <#
    返回两类进程：
      Blocking  = 主程序 / 加载了 profile 插件的进程（它们持有插件文件句柄，必须退出）
      Related   = 与 DSH 相关但并不加载 profile 插件的辅助进程（如浏览器工具用的 electron），提示即可
  #>
  $dshHome = (Get-DshHome).ToLowerInvariant()
  $blocking = @()
  $related = @()
  foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    if ($p.ProcessName -like 'DeepSeek Harness*') { $blocking += $p; continue }
    if ($p.ProcessName -notin @('electron', 'node')) { continue }
    try {
      $path = [string]$p.Path
      if (-not $path) { continue }
      $low = $path.ToLowerInvariant()
      if ($low -like '*deepseek harness\resources\*') { $blocking += $p }
      elseif ($low.Contains($dshHome)) { $related += $p }
    } catch { }
  }
  return [pscustomobject]@{ Blocking = $blocking; Related = $related }
}

# ---------- 执行 ----------
function Invoke-PnpmStep {
  param([string[]]$PnpmArgs, [string]$WorkDir)
  $res = [pscustomobject]@{ Args = ($PnpmArgs -join ' '); ExitCode = -1; Seconds = 0.0; Output = '' }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Push-Location -LiteralPath $WorkDir
  try {
    $raw = & $script:Tools.NodeExe $script:Tools.PnpmScript @PnpmArgs 2>&1
    $res.ExitCode = $LASTEXITCODE
    $res.Output = (($raw | ForEach-Object { "$_" }) -join "`n")
  } catch {
    $res.ExitCode = 1
    $res.Output = "启动失败: $($_.Exception.Message)"
  } finally {
    Pop-Location
    $sw.Stop(); $res.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
  }
  return $res
}

function Read-ProfileDeps([string]$dir) {
  $man = Join-Path $dir 'package.json'
  if (-not (Test-Path -LiteralPath $man)) { Write-Fatal "profile 里没有 package.json: $dir" }
  $obj = Get-Content -LiteralPath $man -Raw -Encoding utf8 | ConvertFrom-Json
  $deps = [ordered]@{}
  foreach ($field in @('dependencies', 'devDependencies', 'optionalDependencies')) {
    $block = $obj.PSObject.Properties[$field]
    if ($block -and $block.Value) {
      foreach ($pr in $block.Value.PSObject.Properties) {
        if (-not $deps.Contains($pr.Name)) { $deps[$pr.Name] = [string]$pr.Value }
      }
    }
  }
  return [pscustomobject]@{ Raw = $obj; Deps = $deps }
}

function New-ProfileBackup([string]$dir) {
  $root = $PSScriptRoot
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $bdir = Join-Path $root ("_backups\profile-$stamp")
  New-Item -ItemType Directory -Force -Path $bdir | Out-Null
  $files = @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml')
  $n = 0
  foreach ($f in $files) {
    $src = Join-Path $dir $f
    if (Test-Path -LiteralPath $src) {
      Copy-Item -LiteralPath $src -Destination (Join-Path $bdir $f) -Force
      $n++
    }
  }
  return [pscustomobject]@{ Dir = $bdir; Count = $n }
}

function Get-DshVersion([string]$dshCmd) {
  if (-not $dshCmd -or -not (Test-Path -LiteralPath $dshCmd)) { return $null }
  try {
    $v = (& $dshCmd -V 2>$null | Select-Object -First 1)
    if ($v -and "$v".Trim()) { return "$v".Trim() }
  } catch { }
  return $null
}

function Invoke-CheckUpdates {
  param([string]$dir, [string]$dshVer, [string]$tag)
  $mjs = Join-Path $PSScriptRoot 'check-updates.mjs'
  if (Test-Path -LiteralPath $mjs) {
    $argv = @($mjs, $dir, '--tag', $tag)
    if ($dshVer) { $argv += @('--dsh', $dshVer) }
    $out = & $script:Tools.NodeExe @argv
    if ($LASTEXITCODE -ne 0 -or -not $out) { Write-Fatal "check-updates.mjs 执行失败（exit $LASTEXITCODE）" }
    return ($out | Out-String | ConvertFrom-Json)
  }

  # 退路：没有 check-updates.mjs 时用 pnpm view 逐个问（拿不到 engines.dsh）
  Write-Warn '没找到 check-updates.mjs，改用 pnpm view 逐个查询（较慢，且不检查 engines.dsh 兼容性）'
  $deps = (Read-ProfileDeps $dir).Deps
  $nonNpm = '^(github:|git\+|git:|file:|link:|workspace:|portal:|https?:|\.{0,2}[\\/])'
  $rows = @()
  foreach ($name in ($deps.Keys | Sort-Object)) {
    $spec = [string]$deps[$name]
    if ($spec -match $nonNpm) {
      $rows += [pscustomobject]@{ name = $name; spec = $spec; kind = 'git'; current = $spec; latest = $null; hasUpdate = $false; enginesDsh = $null; compatible = $null; deprecated = $null; note = 'Git/本地依赖'; unpackedSize = $null }
      continue
    }
    $cur = $spec -replace '^[\^~= ]+', ''
    $latest = $null
    try {
      $r = Invoke-PnpmStep -PnpmArgs @('view', $name, "dist-tags.$tag") -WorkDir $dir
      if ($r.ExitCode -eq 0 -and $r.Output.Trim()) { $latest = ($r.Output.Trim() -split "`n")[-1].Trim().Trim('"', "'") }
    } catch { }
    $hasUpdate = $false
    if ($latest -and $cur -match '^\d+\.\d+\.\d+' -and $latest -ne $cur) { $hasUpdate = ($latest -ne $cur) }
    $rows += [pscustomobject]@{ name = $name; spec = $spec; kind = 'npm'; current = $cur; latest = $latest; hasUpdate = $hasUpdate; enginesDsh = $null; compatible = $null; deprecated = $null; note = $(if ($hasUpdate) { '（未校验兼容性）' } else { $null }); unpackedSize = $null }
  }
  return $rows
}

# ---------- 主流程 ----------
$Tools = $null
function Set-Tools($t) { $script:Tools = $t }

Write-Host ''
Write-Host 'DSH 第三方插件更新（外部执行版）' -ForegroundColor White
Write-Host '绕开「正在被占用」：DSH 完全退出后由本脚本在 profile 目录直接跑 pnpm' -ForegroundColor DarkGray

$dir = Resolve-ProfileDir
Set-Tools (Resolve-Tools)
$nodeVer = (& $script:Tools.NodeExe -v 2>$null)
$pnpmVer = $null
try { $pnpmVer = (& $script:Tools.NodeExe $script:Tools.PnpmScript -v 2>$null | Select-Object -First 1) } catch { }
$dshVer = Get-DshVersion $script:Tools.DshCmd

$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$script:LogPath = Join-Path $logDir ("update-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')

Write-Head '环境'
Write-Info "profile 目录 : $dir"
Write-Info "运行时来源   : $($script:Tools.Source)"
Write-Info "node         : $nodeVer  ($($script:Tools.NodeExe))"
Write-Info "pnpm         : $pnpmVer"
Write-Info "DSH 版本     : $(if ($dshVer) { $dshVer } else { '(未知，跳过引擎兼容性判断)' })"
Write-Info "日志         : $script:LogPath"

# ---- 回滚模式 ----
if ($RollbackFrom) {
  $src = (Resolve-Path -LiteralPath $RollbackFrom -ErrorAction SilentlyContinue)
  if (-not $src) { Write-Fatal "备份目录不存在: $RollbackFrom" }
  $src = $src.Path
  Write-Head '回滚'
  $restored = @()
  foreach ($f in @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml')) {
    $s = Join-Path $src $f
    if (Test-Path -LiteralPath $s) {
      Copy-Item -LiteralPath $s -Destination (Join-Path $dir $f) -Force
      Write-Ok "恢复 $f"
      $restored += $f
    }
  }
  if ($restored -notcontains 'package.json') { Write-Fatal "备份里没有 package.json，无法回滚: $src" }
  # 不用 --frozen-lockfile：备份的 lock 可能与备份的 package.json 不一致（例如只改了 lock），
  # 那样 frozen 会静默装错版本。以 package.json 为准让 pnpm 重新对齐 lock。
  $r = Invoke-PnpmStep -PnpmArgs @('install', '--config.minimum-release-age=0') -WorkDir $dir
  if ($r.ExitCode -eq 0) { Write-Ok "依赖已重装（$($r.Seconds)s）" }
  else {
    Write-Err "pnpm install 失败（exit $($r.ExitCode)，$($r.Seconds)s）"
    Write-Host ($r.Output.Trim() -split "`n" | Select-Object -Last 25 | ForEach-Object { "    $_" }) -ForegroundColor DarkRed
    Write-LogLine $r.Output
    exit 1
  }

  # hoisted 布局下 pnpm 有时只改 lock、不换 node_modules 里的目录（会报 Already up to date），
  # 这时必须 --force 才会真的重新链接。
  function Get-VersionMismatches {
    $depsNow = (Read-ProfileDeps $dir).Deps
    $bad = @()
    foreach ($n in $depsNow.Keys) {
      $spec = [string]$depsNow[$n]
      if ($spec -match '^\d+\.\d+\.\d+') {
        $pj = Join-Path $dir (Join-Path 'node_modules' (Join-Path $n 'package.json'))
        if (Test-Path -LiteralPath $pj) {
          try {
            $iv = (Get-Content -LiteralPath $pj -Raw -Encoding utf8 | ConvertFrom-Json).version
            if ($iv -ne $spec) { $bad += "$n 期望 $spec 实际 $iv" }
          } catch { }
        }
      }
    }
    return $bad
  }
  $mismatch = @(Get-VersionMismatches)
  if ($mismatch.Count -gt 0) {
    Write-Warn ('有 {0} 个包没换回来，用 --force 重新链接…' -f $mismatch.Count)
    $rf = Invoke-PnpmStep -PnpmArgs @('install', '--force', '--config.minimum-release-age=0') -WorkDir $dir
    if ($rf.ExitCode -eq 0) { Write-Ok "已强制重装（$($rf.Seconds)s）" }
    else { Write-Warn " --force 重装失败（exit $($rf.ExitCode)）" ; Write-LogLine $rf.Output }
    $mismatch = @(Get-VersionMismatches)
  }
  if ($mismatch.Count -gt 0) {
    Write-Warn ('回滚后仍有版本不一致: ' + ($mismatch -join '; '))
    Write-Warn '可手动删除 node_modules 后再跑: node pnpm.mjs install'
  } else {
    Write-Ok '已核对，node_modules 里的版本与 package.json 一致。'
  }
  Write-Host ''
  Write-Host '回滚完成，启动 DSH 确认插件版本已退回。' -ForegroundColor Green
  exit 0
}

# ---- 进程检查（真正安装前才强制） ----
$procs = Get-DshProcesses
$blocking = @($procs.Blocking)
$related = @($procs.Related)
$descBlock = ($blocking | ForEach-Object { "PID $($_.Id) $($_.ProcessName)" }) -join '; '
$descRel = ($related | ForEach-Object { "PID $($_.Id) $($_.ProcessName)" }) -join '; '

if ($related.Count -gt 0) {
  Write-Info "另有 DSH 相关的辅助进程（不加载插件，可留）: $descRel"
}

if ($blocking.Count -gt 0) {
  if ($Check -or $DryRun) {
    Write-Warn "检测到 DSH 正在运行：$descBlock"
    Write-Warn '本次只是检查/演练，不需要退出；真正安装时必须先完全退出 DSH。'
  }
  elseif ($Force) {
    Write-Warn "检测到 DSH 正在运行（$descBlock），但指定了 -Force，继续。"
    Write-Warn '插件目录被占用时 pnpm 会报 EPERM，且重试前可能已清掉目标目录里的部分文件。'
  }
  else {
    Write-Host ''
    Write-Host 'DSH 还在运行，不能更新。' -ForegroundColor Yellow
    Write-Host "  正在运行的进程: $descBlock" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '为什么必须先退出：' -ForegroundColor Gray
    Write-Host '  DSH 运行时会加载插件 JS，Windows 上文件句柄被占，pnpm 无法把新版本目录 rename 进去。' -ForegroundColor DarkGray
    Write-Host '  市场里那个「正在被占用」就是这个原因，重试多少次都一样。' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '正确做法：' -ForegroundColor Gray
    Write-Host '  1) 完全退出 DSH（托盘图标也退出，任务管理器里不该再看到 DeepSeek Harness）' -ForegroundColor DarkGray
    Write-Host '  2) 从开始菜单/任务栏另开一个 PowerShell 窗口（不要用 DSH 内置终端，会被一起关掉）' -ForegroundColor DarkGray
    Write-Host "  3) 重新运行: pwsh -File `"$PSCommandPath`"" -ForegroundColor DarkGray
    Write-Host ''
    if ([Console]::IsInputRedirected) {
      Write-Fatal '当前是非交互环境，无法等待确认。退出 DSH 后重跑，或加 -Force 强行继续。'
    }
    $ans = Read-Host '如果 DSH 已经全部退出，输入 y 继续；否则直接回车退出 [y/N]'
    if ($ans -notmatch '^(y|yes|是)$') { Write-Host '已取消。' -ForegroundColor Gray; exit 0 }
    Start-Sleep -Milliseconds 800
    $still = @((Get-DshProcesses).Blocking)
    if ($still.Count -gt 0) {
      Write-Fatal ('DSH 进程仍在: ' + (($still | ForEach-Object { "PID $($_.Id)" }) -join ', ') + '。请确认已完全退出。')
    }
  }
}
else {
  Write-Ok 'DSH 未运行，可以安全更新。'
}

# ---- 查新版本 ----
Write-Head "检查更新（dist-tag: $Tag）"
$rows = @(Invoke-CheckUpdates -dir $dir -dshVer $dshVer -tag $Tag)
$updatable = @($rows | Where-Object { $_.hasUpdate })
$gitDeps = @($rows | Where-Object { $_.kind -eq 'git' })

$view = $rows | Select-Object @{ n = '插件'; e = { $_.name } },
  @{ n = '当前'; e = { if ($_.current) { $_.current } else { '(范围)' } } },
  @{ n = '最新'; e = { if ($_.latest) { $_.latest } else { '-' } } },
  @{ n = '可更新'; e = { if ($_.hasUpdate) { '是' } else { '' } } },
  @{ n = '引擎要求'; e = { if ($_.enginesDsh) { $_.enginesDsh } else { '' } } },
  @{ n = '兼容'; e = { if ($null -eq $_.compatible) { '' } elseif ($_.compatible) { 'ok' } else { '否' } } },
  @{ n = '备注'; e = { $_.note } }
Write-Host ($view | Format-Table -AutoSize | Out-String -Width 200).TrimEnd()

Write-Info "共 $($rows.Count) 个依赖，可更新 $($updatable.Count) 个，Git/本地依赖 $($gitDeps.Count) 个。"
if ($gitDeps.Count -gt 0 -and -not $IncludeGit) {
  Write-Info ('跳过 Git/本地依赖: ' + (($gitDeps | ForEach-Object { $_.name }) -join ', '))
}

if ($Check) {
  Write-Host ''
  Write-Host '仅检查模式，未做任何修改。' -ForegroundColor Green
  exit 0
}
if ($updatable.Count -eq 0) {
  Write-Host ''
  Write-Host '全部插件已是最新。' -ForegroundColor Green
  exit 0
}

# ---- 目标筛选 ----
$targets = $updatable
if ($Only.Count -gt 0) {
  $targets = @()
  foreach ($pat in $Only) {
    $hit = @($updatable | Where-Object { $_.name -like $pat })
    if ($hit.Count -eq 0) {
      $known = @($rows | Where-Object { $_.name -like $pat })
      if ($known.Count -gt 0) { Write-Warn "$pat 没有新版本，跳过" }
      else { Write-Warn "$pat 不在 profile 的依赖里，跳过" }
    }
    $targets += $hit
  }
  $targets = @($targets | Sort-Object name -Unique)
}
if (-not $IncludeGit) { $targets = @($targets | Where-Object { $_.kind -ne 'git' }) }
if ($targets.Count -eq 0) {
  Write-Host ''
  Write-Host '没有需要处理的插件。' -ForegroundColor Green
  exit 0
}

# ---- 兼容性筛 ----
$chosen = @()
foreach ($t in $targets) {
  if ($t.compatible -eq $false -and -not $AllowIncompatible) {
    Write-Warn ("跳过 {0}：它要求 DSH {1}，当前是 {2}（要强行装加 -AllowIncompatible）" -f $t.name, $t.enginesDsh, $dshVer)
    continue
  }
  if ($t.deprecated) { Write-Warn ("{0} 的最新版被标记为已废弃：{1}" -f $t.name, $t.deprecated) }
  $chosen += $t
}
if ($chosen.Count -eq 0) {
  Write-Host ''
  Write-Host '筛选后没有可安装的插件。' -ForegroundColor Green
  exit 0
}

$specs = @($chosen | ForEach-Object { "$($_.name)@$($_.latest)" })
$baseArgs = @('add', '-w', '--save-exact', '--config.minimum-release-age=0')

Write-Head '计划'
foreach ($t in $chosen) {
  $sizeTxt = ''
  if ($t.unpackedSize) { $sizeTxt = '  [' + [Math]::Round($t.unpackedSize / 1MB) + ' MB]' }
  Write-Info ("{0}  {1} -> {2}{3}" -f $t.name, $t.current, $t.latest, $sizeTxt)
}
Write-LogLine ('plan: ' + (($chosen | ForEach-Object { "$($_.name)@$($_.latest)" }) -join ' '))

if ($DryRun) {
  Write-Head '将执行的命令（-DryRun，未实际运行）'
  if ($Batch) {
    Write-Host ('  cd "{0}"' -f $dir) -ForegroundColor DarkGray
    Write-Host ('  node "{0}" {1} {2}' -f $script:Tools.PnpmScript, ($baseArgs -join ' '), ($specs -join ' ')) -ForegroundColor DarkGray
  }
  else {
    foreach ($t in $chosen) {
      Write-Host ('  cd "{0}"' -f $dir) -ForegroundColor DarkGray
      Write-Host ('  node "{0}" {1} {2}@{3}' -f $script:Tools.PnpmScript, ($baseArgs -join ' '), $t.name, $t.latest) -ForegroundColor DarkGray
      Write-Host ''
    }
  }
  Write-Host '演练结束，未做任何修改。' -ForegroundColor Green
  exit 0
}

# ---- 备份 ----
if ($NoBackup) {
  Write-Warn '已指定 -NoBackup，跳过备份（出问题时只能手动改回 package.json）。'
  $backup = $null
}
else {
  Write-Head '备份'
  $backup = New-ProfileBackup $dir
  Write-Ok "已备份 $($backup.Count) 个文件 -> $($backup.Dir)"
  Write-Info ("回滚: pwsh -File `"{0}`" -RollbackFrom `"{1}`"" -f $PSCommandPath, $backup.Dir)
}

# ---- 更新 ----
Write-Head '更新'
$results = @()
$failed = @()

if ($Batch) {
  Write-Info ("一次性安装 {0} 个: {1}" -f $specs.Count, ($specs -join ' '))
  $r = Invoke-PnpmStep -PnpmArgs ($baseArgs + $specs) -WorkDir $dir
  $okAll = ($r.ExitCode -eq 0)
  foreach ($t in $chosen) {
    $results += [pscustomobject]@{ name = $t.name; from = $t.current; to = $t.latest; ok = $okAll; seconds = $r.Seconds; detail = $(if ($okAll) { '' } else { "整批失败 exit=$($r.ExitCode)" }) }
    if (-not $okAll) { $failed += $t.name }
  }
  if ($okAll) { Write-Ok ("整批完成（{0}s）" -f $r.Seconds) }
  else {
    Write-Err ("整批失败（exit {0}, {1}s）" -f $r.ExitCode, $r.Seconds)
    ($r.Output.Trim() -split "`n" | Select-Object -Last 30) | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed; Write-LogLine "    $_" }
  }
}
else {
  $i = 0
  foreach ($t in $chosen) {
    $i++
    $spec = "$($t.name)@$($t.latest)"
    Write-Host ("  [{0}/{1}] {2} ..." -f $i, $chosen.Count, $t.name) -ForegroundColor White
    $r = Invoke-PnpmStep -PnpmArgs ($baseArgs + $spec) -WorkDir $dir
    if ($r.ExitCode -eq 0) {
      Write-Ok ("{0} {1} -> {2}  ({3}s)" -f $t.name, $t.current, $t.latest, $r.Seconds)
      $results += [pscustomobject]@{ name = $t.name; from = $t.current; to = $t.latest; ok = $true; seconds = $r.Seconds; detail = '' }
    }
    else {
      Write-Err ("{0} 失败（exit {1}, {2}s）" -f $t.name, $r.ExitCode, $r.Seconds)
      $tail = @($r.Output.Trim() -split "`n" | Select-Object -Last 20)
      $tail | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkRed; Write-LogLine "      $_" }
      $hint = ''
      if ($r.Output -match 'EPERM|EBUSY|being used by another process|operation not permitted|failed to remove existing directory') {
        $hint = '文件被占用 —— DSH 或它的子进程还没退干净'
      } elseif ($r.Output -match 'ERR_PNPM_ADDING_TO_ROOT') {
        $hint = '缺少 -w（profile 是 pnpm workspace root）'
      } elseif ($r.Output -match 'ERR_PNPM_NO_MATCHING_VERSION|No matching version') {
        $hint = '该版本在 registry 上不存在，或需要 -Tag'
      } elseif ($r.Output -match 'ERR_PNPM_FETCH|ENOTFOUND|ETIMEDOUT|ECONNRESET|401|403') {
        $hint = '网络/凭据问题'
      }
      if ($hint) { Write-Warn "  可能原因: $hint" }
      $results += [pscustomobject]@{ name = $t.name; from = $t.current; to = $t.latest; ok = $false; seconds = $r.Seconds; detail = $(if ($hint) { $hint } else { "exit $($r.ExitCode)" }) }
      $failed += $t.name
    }
  }
}

# ---- 校验 ----
Write-Head '校验'
$after = (Read-ProfileDeps $dir).Deps
foreach ($t in $chosen) {
  $want = [string]$t.latest
  $specNow = [string]$after[$t.name]
  $clean = $specNow -replace '^[\^~= ]+', ''
  $pkgJson = Join-Path $dir (Join-Path 'node_modules' (Join-Path $t.name 'package.json'))
  $installedVer = $null
  if (Test-Path -LiteralPath $pkgJson) {
    try { $installedVer = (Get-Content -LiteralPath $pkgJson -Raw -Encoding utf8 | ConvertFrom-Json).version } catch { }
  }
  $okPackage = ($clean -eq $want)
  $okDir = ($installedVer -eq $want)
  if ($okPackage -and $okDir) {
    Write-Ok ("{0} 已是 {1}" -f $t.name, $want)
  }
  elseif ($okPackage -and -not $installedVer) {
    Write-Warn ("{0} package.json 已指向 {1}，但 node_modules 里没有它的 package.json（下次启动会重装）" -f $t.name, $want)
  }
  elseif ($okPackage) {
    Write-Warn ("{0} package.json 已指向 {1}，node_modules 里仍是 {2}（下次启动会纠正）" -f $t.name, $want, $installedVer)
  }
  else {
    Write-Warn ("{0} package.json 里现在是 {1}，期望 {2}" -f $t.name, $specNow, $want)
  }
}

# ---- 汇总 ----
Write-Head '结果'
$okCount = @($results | Where-Object { $_.ok }).Count
if ($results.Count -gt 0) {
  $tbl = $results | Select-Object @{ n = '插件'; e = { $_.name } },
    @{ n = '原版本'; e = { $_.from } },
    @{ n = '目标'; e = { $_.to } },
    @{ n = '结果'; e = { if ($_.ok) { '成功' } else { '失败' } } },
    @{ n = '耗时'; e = { "$($_.seconds)s" } },
    @{ n = '说明'; e = { $_.detail } }
  Write-Host ($tbl | Format-Table -AutoSize | Out-String -Width 200).TrimEnd()
}
Write-Host ''
if ($failed.Count -eq 0) {
  Write-Host ("全部完成：{0} 个插件已更新。" -f $okCount) -ForegroundColor Green
} else {
  Write-Host ("部分失败：成功 {0} 个，失败 {1} 个 -> {2}" -f $okCount, $failed.Count, ($failed -join ', ')) -ForegroundColor Yellow
  if ($backup) {
    Write-Host ''
    Write-Host '如果 profile 现在状态不对，可整份回滚：' -ForegroundColor Gray
    Write-Host ("  pwsh -File `"{0}`" -RollbackFrom `"{1}`"" -f $PSCommandPath, $backup.Dir) -ForegroundColor DarkGray
  }
}
Write-Host ''
Write-Host '下一步：正常启动 DSH，插件即按新版本加载。' -ForegroundColor White
if ($backup) { Write-Host ("备份保留在 {0}，确认新版本没问题后可手动删除。" -f $backup.Dir) -ForegroundColor DarkGray }
Write-Host ("日志: {0}" -f $script:LogPath) -ForegroundColor DarkGray
Write-LogLine ("done ok=$okCount fail=$($failed.Count)")

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
