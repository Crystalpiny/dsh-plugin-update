<#
.SYNOPSIS
    一键更新 DSH（DeepSeek Harness）profile 中的第三方插件。

.DESCRIPTION
    脚本读取 DSH profile 的 package.json，向 npm registry 查询每个插件的最新版本，
    再通过 DSH 自带的 `dsh plugin add <包>@<版本>` 逐个更新（复用桌面端内置的 pnpm
    与版本兼容性预检），保留 profile 原来的版本号写法（精确版本 / ^ / ~）。

    更新前会把 package.json、pnpm-lock.yaml、pnpm-workspace.yaml 备份到
    <profile>\.plugin-updates\<profile>-<时间>，失败或想还原时用 -Restore 回滚。

    注意：DSH 桌面端运行时持有 profile 写入锁，真正的更新需要先从托盘完全退出
    DeepSeek Harness。只读的 -Check / -DryRun 可以在运行中安全使用。

.PARAMETER ProfileName
    要处理的 profile 名称，默认 desktop。

.PARAMETER AllProfiles
    处理 $DSH_HOME\profiles 下所有含 package.json 的 profile。

.PARAMETER Check
    只检查并列出可更新的插件，不写入任何文件（可在 DSH 运行时使用）。

.PARAMETER DryRun
    显示将要执行的 dsh 命令，但不真正更新（可在 DSH 运行时使用）。

.PARAMETER Yes
    不再询问确认，直接更新。

.PARAMETER Force
    跳过“DSH 桌面端正在运行”的检查（仅在进程检测误报时使用）。profile 写入锁被活动进程持有时仍会拒绝执行。

.PARAMETER Only
    只处理名称匹配的插件，支持通配符，如 -Only dsh-ops,dsh-*。

.PARAMETER Skip
    跳过名称匹配的插件，支持通配符。

.PARAMETER DshCli
    dsh.cmd 的路径。默认依次从运行中的桌面端、PATH、常见安装目录、卸载注册表查找。

.PARAMETER Registry
    查询最新版本用的 npm registry。默认读取 profile / $DSH_HOME / 用户目录下的 .npmrc，
    再退回 https://registry.npmjs.org/。

.PARAMETER NoBackup
    不创建备份。

.PARAMETER ContinueOnError
    某个插件更新失败后继续处理其余插件。

.PARAMETER IncludeOfficial
    也更新 @deepseek-ai/* 官方运行时包（默认跳过，它们随桌面端一起发布）。

.PARAMETER Restart
    更新结束后启动 DeepSeek Harness。

.PARAMETER Restore
    回滚到指定备份目录（也可以传 .plugin-updates 根目录，自动取最新一份），并重新 install。

.EXAMPLE
    .\Update-DshPlugins.ps1 -Check

    查看哪些插件可以更新（DSH 开着也能用）。

.EXAMPLE
    .\Update-DshPlugins.ps1

    退出 DSH 后运行，确认后更新全部插件。

.EXAMPLE
    .\Update-DshPlugins.ps1 -Only dsh-claude-style,dsh-context -Yes

    只更新两个插件，不再询问。

.EXAMPLE
    .\Update-DshPlugins.ps1 -Restore "$env:USERPROFILE\.dsh\profiles\desktop\.plugin-updates\desktop-20261021-221500"

    回滚到指定备份。
#>

[CmdletBinding()]
param(
    [string]$ProfileName = 'desktop',
    [switch]$AllProfiles,
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Force,
    [string[]]$Only = @(),
    [string[]]$Skip = @(),
    [string]$DshCli,
    [string]$Registry,
    [switch]$NoBackup,
    [switch]$ContinueOnError,
    [switch]$IncludeOfficial,
    [switch]$Restart,
    [string]$Restore
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:DshHome = $null
$script:Cli = $null
$script:Blocked = $false
$script:Failed = $false
$script:PrevConsoleEncoding = $null

try {
    if ([Console]::OutputEncoding.WebName -ne 'utf-8') {
        $script:PrevConsoleEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
} catch { }

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }


# ============================================================================
#  输出
# ============================================================================

function Write-Info {
    param([string]$Text)
    Write-Host ('  ' + $Text) -ForegroundColor Gray
}

function Write-Ok {
    param([string]$Text)
    Write-Host ('  ' + $Text) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host ('  [注意] ' + $Text) -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Text)
    Write-Host ('  [错误] ' + $Text) -ForegroundColor Red
}

function Write-Action {
    param([string]$Text)
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
}


# ============================================================================
#  基础工具
# ============================================================================

function Get-DshHome {
    if ($env:DSH_HOME -and $env:DSH_HOME.Trim()) {
        return [IO.Path]::GetFullPath($env:DSH_HOME.Trim())
    }
    $profileRoot = [Environment]::GetFolderPath('UserProfile')
    return (Join-Path $profileRoot '.dsh')
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "文件不存在：$Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    return ($raw | ConvertFrom-Json)
}

function Test-NameMatch {
    param([string]$Name, [string[]]$Patterns)
    if (-not $Patterns) { return $false }
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Name -like $pattern.Trim()) { return $true }
    }
    return $false
}

function Get-DisplayWidth {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE4F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

function Format-Cell {
    param([string]$Text, [int]$Width, [switch]$Right)
    if ($null -eq $Text) { $Text = '' }
    $padding = ' ' * [Math]::Max(0, $Width - (Get-DisplayWidth $Text))
    if ($Right) { return ($padding + $Text) }
    return ($Text + $padding)
}

function Compare-DshVersion {
    param([string]$Left, [string]$Right)

    $parse = {
        param([string]$Value)
        if (-not $Value) { return $null }
        $clean = $Value.Trim() -replace '^[\^~<>=v ]+', ''
        $match = [regex]::Match($clean, '^(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$')
        if (-not $match.Success) { return $null }
        $numbers = @()
        foreach ($part in $match.Groups[1].Value.Split('.')) { $numbers += [int]$part }
        return [pscustomobject]@{ Numbers = $numbers; Pre = $(if ($match.Groups[2].Success) { $match.Groups[2].Value } else { $null }) }
    }

    $a = & $parse $Left
    $b = & $parse $Right
    if (-not $a -or -not $b) { return [string]::CompareOrdinal([string]$Left, [string]$Right) }

    $count = [Math]::Max($a.Numbers.Count, $b.Numbers.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $x = if ($i -lt $a.Numbers.Count) { $a.Numbers[$i] } else { 0 }
        $y = if ($i -lt $b.Numbers.Count) { $b.Numbers[$i] } else { 0 }
        if ($x -ne $y) { return [Math]::Sign($x - $y) }
    }
    if (-not $a.Pre -and -not $b.Pre) { return 0 }
    if (-not $a.Pre) { return 1 }
    if (-not $b.Pre) { return -1 }
    return [string]::CompareOrdinal($a.Pre, $b.Pre)
}

function Get-VersionFromSpecifier {
    param([string]$Spec)
    if (-not $Spec) { return $null }
    $match = [regex]::Match($Spec, '\d+(?:\.\d+){1,2}(?:-[0-9A-Za-z.-]+)?')
    if ($match.Success) { return $match.Value }
    return $null
}

function Test-RegistrySpecifier {
    param([string]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec)) { return $false }
    if ($Spec -match '^(file:|link:|workspace:|portal:|git\+|git:|github:|https?:|ssh:|npm:)') { return $false }
    if ($Spec -match '#') { return $false }
    if ($Spec -match '\.git($|#)') { return $false }
    return $true
}

function Get-SaveFlags {
    param([string]$Spec)
    if ($Spec -match '^\^') { return @('--save-prefix=^') }
    if ($Spec -match '^~')  { return @('--save-prefix=~') }
    return @('--save-exact')
}


# ============================================================================
#  定位安装 / 进程 / 锁
# ============================================================================

function Get-DshAppProcesses {
    $result = @()
    $cim = $null
    $cimAvailable = $true
    try {
        $cim = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'DeepSeek Harness.exe'" -ErrorAction Stop
    } catch {
        $cim = $null
        $cimAvailable = $false
    }
    foreach ($proc in @($cim)) {
        if (-not $proc) { continue }
        $commandLine = [string]$proc.CommandLine
        # 排除 Chromium 子进程、dsh CLI/宿主进程，以及本工具自己的子进程运行器
        if ($commandLine -match '--type=') { continue }
        if ($commandLine -match '--expose-internals') { continue }
        if ($commandLine -match 'dsh-subprocess-local|runner\.js') { continue }
        $result += [pscustomobject]@{
            Id             = $proc.ProcessId
            Name           = $proc.Name
            ExecutablePath = $proc.ExecutablePath
            CommandLine    = $commandLine
        }
    }

    if (-not $cimAvailable) {
        # CIM 不可用时退回 Get-Process（无法区分 helper 进程，宁可保守）
        foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^DeepSeek.*Harness' })) {
            if (-not $proc) { continue }
            $path = $null
            try { $path = $proc.Path } catch { }
            $result += [pscustomobject]@{ Id = $proc.Id; Name = $proc.ProcessName; ExecutablePath = $path; CommandLine = '' }
        }
    }
    return $result
}

function Get-InstallRootsFromRegistry {
    $roots = @()
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $keys) {
        try {
            $items = Get-ItemProperty -Path $key -ErrorAction Stop
        } catch {
            continue
        }
        foreach ($item in @($items)) {
            if ($item.DisplayName -match 'DeepSeek Harness' -and $item.InstallLocation) {
                $roots += [string]$item.InstallLocation
            }
        }
    }
    return $roots
}

function Resolve-DshCli {
    param([string]$Hint)

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($Hint) {
        $h = $Hint.Trim().Trim('"')
        if (Test-Path -LiteralPath $h -PathType Container) {
            foreach ($rel in @('resources\runtime\cli\bin\dsh.cmd', 'runtime\cli\bin\dsh.cmd', 'dsh.cmd')) {
                $candidates.Add((Join-Path $h $rel))
            }
        } elseif ($h -match '(?i)DeepSeek Harness\.exe$') {
            $candidates.Add((Join-Path (Split-Path -Parent $h) 'resources\runtime\cli\bin\dsh.cmd'))
        } else {
            $candidates.Add($h)
        }
    }

    foreach ($name in @('dsh.cmd', 'dsh')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($command -and $command.Source) { $candidates.Add($command.Source) }
    }

    foreach ($proc in @(Get-DshAppProcesses)) {
        if ($proc.ExecutablePath) {
            $candidates.Add((Join-Path (Split-Path -Parent $proc.ExecutablePath) 'resources\runtime\cli\bin\dsh.cmd'))
        }
    }

    $roots = @()
    if ($env:LOCALAPPDATA) {
        $roots += (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness')
        $roots += (Join-Path $env:LOCALAPPDATA 'Programs\deepseek-harness')
        $roots += (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness')
    }
    if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles 'DeepSeek Harness') }
    if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness') }
    $roots += (Get-InstallRootsFromRegistry)

    foreach ($root in $roots) {
        if ($root) { $candidates.Add((Join-Path $root 'resources\runtime\cli\bin\dsh.cmd')) }
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-AppExeFromCli {
    param([string]$CliPath)
    if (-not $CliPath) { return $null }
    $bin = Split-Path -Parent $CliPath
    $install = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bin)))
    $exe = Join-Path $install 'DeepSeek Harness.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    return $null
}

function Get-ProfileLockState {
    param([string]$ProfileDir)

    $lockPath = Join-Path $ProfileDir 'package.json.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) {
        return [pscustomobject]@{ Exists = $false; Path = $lockPath; HolderPid = 0; ProcessName = ''; Alive = $false }
    }

    $raw = ''
    try { $raw = (Get-Content -LiteralPath $lockPath -Raw -ErrorAction Stop).Trim() } catch { }
    $holderPid = 0
    if ($raw -match '^\d+$') { $holderPid = [int]$raw }

    $processName = ''
    $alive = $false
    if ($holderPid -gt 0) {
        $proc = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
        if ($proc) {
            $alive = $true
            $processName = $proc.ProcessName
        }
    }
    return [pscustomobject]@{
        Exists      = $true
        Path        = $lockPath
        HolderPid   = $holderPid
        ProcessName = $processName
        Alive       = $alive
    }
}

function Assert-Writable {
    param([string]$Profile, [string]$ProfileDir)

    if ($Profile -eq 'desktop') {
        $apps = @(Get-DshAppProcesses)
        if ($apps.Count -gt 0) {
            $pids = ($apps | ForEach-Object { $_.Id }) -join ', '
            if (-not $Force) {
                throw "DSH 桌面端正在运行（PID $pids）。请先从托盘菜单彻底退出 DeepSeek Harness，再重新运行本脚本。"
            }
            Write-Warn "DSH 桌面端仍在运行（PID $pids）；-Force 已跳过检查，更新可能被热加载或文件占用干扰。"
        }
    }

    $lock = Get-ProfileLockState -ProfileDir $ProfileDir
    if ($lock.Exists) {
        if ($lock.Alive) {
            $owner = if ($lock.ProcessName) { $lock.ProcessName } else { '未知进程' }
            throw ("profile 写入锁被 PID {0}（{1}）持有，此时写入会冲突并超时。请完全退出 DeepSeek Harness 或结束该进程后重试；进程退出后 dsh 会自动接管遗留的锁文件。" -f $lock.HolderPid, $owner)
        }
        Write-Info ("发现上次遗留的配置锁（PID {0} 已退出），dsh 会自动接管，无需手动删除。" -f $lock.HolderPid)
    }
}


# ============================================================================
#  registry 查询
# ============================================================================

function Get-RegistryForProfile {
    param([string]$ProfileDir)

    if ($Registry) { return $Registry.TrimEnd('/') }

    $candidates = @(
        (Join-Path $ProfileDir '.npmrc'),
        (Join-Path $script:DshHome '.npmrc'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.npmrc')
    )
    foreach ($file in $candidates) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
            $match = [regex]::Match($line, '^\s*registry\s*=\s*(\S+)\s*$')
            if ($match.Success) { return $match.Groups[1].Value.TrimEnd('/') }
        }
    }
    if ($env:npm_config_registry) { return $env:npm_config_registry.TrimEnd('/') }
    return 'https://registry.npmjs.org'
}

function Get-LatestVersion {
    param([string]$Package, [string]$RegistryBase)

    $base = $RegistryBase.TrimEnd('/')
    $escaped = [Uri]::EscapeDataString($Package)
    $lastError = '未知错误'

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri ("{0}/{1}/latest" -f $base, $escaped) -TimeoutSec 20 -Headers @{ Accept = 'application/json' } -ErrorAction Stop
            if ($response -and $response.version) { return [string]$response.version }
            $lastError = '响应中没有 version 字段'
        } catch {
            $lastError = $_.Exception.Message
            $statusCode = 0
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
            if ($statusCode -eq 404) {
                # 个别 registry 不支持 /<pkg>/latest，退回完整 packument
                try {
                    $document = Invoke-RestMethod -Uri ("{0}/{1}" -f $base, $escaped) -TimeoutSec 20 -ErrorAction Stop
                    if ($document.'dist-tags'.latest) { return [string]$document.'dist-tags'.latest }
                } catch {
                    $lastError = $_.Exception.Message
                }
                break
            }
        }
        Start-Sleep -Milliseconds 400
    }
    throw ("无法从 {0} 获取 {1} 的最新版本：{2}" -f $base, $Package, $lastError)
}


# ============================================================================
#  profile 读取 / 表格
# ============================================================================

function Get-InstalledVersion {
    param([string]$ProfileDir, [string]$Package)
    $packageDir = Join-Path (Join-Path $ProfileDir 'node_modules') ($Package -replace '/', '\')
    $manifest = Join-Path $packageDir 'package.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    try {
        return [string](Read-JsonFile -Path $manifest).version
    } catch {
        return $null
    }
}

function Test-ProfileInstalled {
    param([string]$ProfileDir)

    $manifest = Read-JsonFile -Path (Join-Path $ProfileDir 'package.json')
    $mismatches = @()
    if (-not ($manifest.PSObject.Properties['dependencies'] -and $manifest.dependencies)) {
        return $mismatches
    }
    foreach ($property in $manifest.dependencies.PSObject.Properties) {
        $spec = [string]$property.Value
        # 只校验精确版本；范围 / git / file 等写法无法用已安装版本简单比对
        if ($spec -notmatch '^\d+\.\d+\.\d+') { continue }
        $installed = Get-InstalledVersion -ProfileDir $ProfileDir -Package $property.Name
        if ($installed -ne $spec) {
            $mismatches += ("{0} 清单 {1} / 已安装 {2}" -f $property.Name, $spec, $(if ($installed) { $installed } else { '缺失' }))
        }
    }
    return $mismatches
}

function Show-PluginTable {
    param([object[]]$Entries)

    if (-not $Entries -or $Entries.Count -eq 0) {
        Write-Info '（没有可显示的插件）'
        return
    }

    $nameWidth = 24
    foreach ($entry in $Entries) {
        $nameWidth = [Math]::Max($nameWidth, (Get-DisplayWidth ([string]$entry.Name)))
    }
    $nameWidth = [Math]::Min($nameWidth, 46)
    $versionWidth = 12

    $header = '  ' + (Format-Cell '插件' $nameWidth) + '  ' + (Format-Cell '当前' $versionWidth) + (Format-Cell '最新' $versionWidth) + '状态'
    Write-Host $header -ForegroundColor DarkGray
    Write-Host ('  ' + ('-' * (Get-DisplayWidth $header))) -ForegroundColor DarkGray

    foreach ($entry in $Entries) {
        $line = '  ' +
            (Format-Cell ([string]$entry.Name) $nameWidth) + '  ' +
            (Format-Cell ([string]$entry.Current) $versionWidth) +
            (Format-Cell ([string]$entry.Latest) $versionWidth) +
            [string]$entry.Status
        $color = switch ($entry.Kind) {
            'ok'    { 'Green' }
            'warn'  { 'Yellow' }
            'error' { 'Red' }
            'muted' { 'DarkGray' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Get-LastOperationLog {
    param([string]$ProfileDir)
    $root = Join-Path $ProfileDir '.plugin-manager\logs'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $newest = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $newest) { return $null }
    $log = Join-Path $newest.FullName 'pnpm.log'
    if (Test-Path -LiteralPath $log) { return $log }
    return $null
}

function Write-FailureDetail {
    param([string]$ProfileDir)

    $log = Get-LastOperationLog -ProfileDir $ProfileDir
    if (-not $log) { return }
    Write-Info ("诊断日志：{0}" -f $log)
    $lines = @(Get-Content -LiteralPath $log -Tail 80 -ErrorAction SilentlyContinue)
    $hits = @($lines | Where-Object {
        $_ -match '^\s*dsh:' -or $_ -match 'ERR_PNPM' -or $_ -match 'EACCES|EPERM|ENOSPC|ETIMEDOUT|ENOTFOUND|ECONNREFUSED'
    } | Select-Object -Last 8)
    foreach ($hit in $hits) {
        Write-Host ('    ' + $hit.Trim()) -ForegroundColor DarkYellow
    }
}


# ============================================================================
#  备份 / 回滚
# ============================================================================

function New-ProfileBackup {
    param([string]$Profile, [string]$ProfileDir, [object[]]$Planned)

    $root = Join-Path $ProfileDir '.plugin-updates'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = Join-Path $root ("{0}-{1}" -f $Profile, $stamp)

    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($file in @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml')) {
        $source = Join-Path $ProfileDir $file
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $target $file) -Force
        }
    }

    $metadata = [ordered]@{
        tool       = 'Update-DshPlugins.ps1'
        profile    = $Profile
        profileDir = $ProfileDir
        createdAt  = (Get-Date).ToString('o')
        planned    = @($Planned | ForEach-Object {
            [ordered]@{ name = $_.Name; from = $_.Current; to = $_.Latest }
        })
    }
    ($metadata | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $target 'backup.json') -Encoding UTF8
    return $target
}

function Invoke-RestoreAction {
    param([string]$BackupInput, [string]$CliPath)

    $backupDir = $BackupInput.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
        throw "备份目录不存在：$backupDir"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $backupDir 'backup.json'))) {
        $candidates = @(Get-ChildItem -LiteralPath $backupDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'backup.json') } |
            Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -eq 0) { throw "目录中没有可用的备份：$backupDir" }
        $backupDir = $candidates[0].FullName
    }

    $metadata = Read-JsonFile -Path (Join-Path $backupDir 'backup.json')
    $profile = [string]$metadata.profile
    $profileDir = [string]$metadata.profileDir

    if (-not $profile) { throw "备份缺少 profile 信息：$backupDir" }
    if (-not $profileDir -or -not (Test-Path -LiteralPath (Join-Path $profileDir 'package.json'))) {
        $profileDir = Join-Path (Join-Path $script:DshHome 'profiles') $profile
    }
    if (-not (Test-Path -LiteralPath (Join-Path $profileDir 'package.json'))) {
        throw "找不到备份对应的 profile 目录：$profileDir"
    }

    Write-Info ("备份目录 : {0}" -f $backupDir)
    Write-Info ("创建时间 : {0}" -f $metadata.createdAt)
    Write-Info ("profile  : {0}  ({1})" -f $profile, $profileDir)

    Assert-Writable -Profile $profile -ProfileDir $profileDir

    $hadLockfile = Test-Path -LiteralPath (Join-Path $backupDir 'pnpm-lock.yaml')

    foreach ($file in @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml')) {
        $source = Join-Path $backupDir $file
        $destination = Join-Path $profileDir $file
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
            Write-Info ("已还原 {0}" -f $file)
        } elseif ($file -eq 'pnpm-lock.yaml' -and (Test-Path -LiteralPath $destination)) {
            # 备份时没有锁文件，说明当前的锁文件是更新时新生成的，必须移除
            Remove-Item -LiteralPath $destination -Force
            Write-Info '已移除更新过程中生成的 pnpm-lock.yaml'
        }
    }

    $installArgs = @('plugin', '--profile', $profile, 'install')
    if ($hadLockfile) { $installArgs += '--frozen-lockfile' }

    Write-Action ("正在重新安装（dsh plugin --profile {0} install）..." -f $profile)
    & $CliPath @installArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Err ("重新安装失败（退出码 {0}），请查看上方输出。" -f $exitCode)
        Write-FailureDetail -ProfileDir $profileDir
        $script:Failed = $true
        return
    }

    # pnpm 偶尔会以 node_modules 的既有状态判定“已是最新”，版本不符时强制重装一次
    $mismatches = @(Test-ProfileInstalled -ProfileDir $profileDir)
    if ($mismatches.Count -gt 0) {
        Write-Warn ("安装结果与备份清单不一致（{0}），执行 --force 重装..." -f ($mismatches -join '; '))
        $forceArgs = @('plugin', '--profile', $profile, 'install')
        if ($hadLockfile) { $forceArgs += '--frozen-lockfile' }
        $forceArgs += '--force'
        & $CliPath @forceArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-Err ("强制重装失败（退出码 {0}）。" -f $exitCode)
            Write-FailureDetail -ProfileDir $profileDir
            $script:Failed = $true
            return
        }
        $mismatches = @(Test-ProfileInstalled -ProfileDir $profileDir)
        if ($mismatches.Count -gt 0) {
            Write-Err ("仍有依赖版本未还原：{0}" -f ($mismatches -join '; '))
            $script:Failed = $true
            return
        }
    }

    $restored = Read-JsonFile -Path (Join-Path $profileDir 'package.json')
    if ($restored.PSObject.Properties['dependencies'] -and $restored.dependencies) {
        Write-Host ''
        foreach ($property in $restored.dependencies.PSObject.Properties) {
            $installed = Get-InstalledVersion -ProfileDir $profileDir -Package $property.Name
            $shown = if ($installed) { $installed } else { '未安装' }
            Write-Info ("{0} = {1}  (已安装 {2})" -f $property.Name, $property.Value, $shown)
        }
    }
    Write-Ok '回滚完成。请重新启动 DeepSeek Harness。'
}


# ============================================================================
#  更新
# ============================================================================

function Invoke-ProfileUpdate {
    param(
        [string]$Profile,
        [string]$ProfileDir,
        [string]$RegistryBase,
        [string]$CliPath
    )

    $manifestPath = Join-Path $ProfileDir 'package.json'
    $manifest = Read-JsonFile -Path $manifestPath

    $entries = @()
    $depsProperty = $manifest.PSObject.Properties['dependencies']
    if ($depsProperty -and $depsProperty.Value) {
        foreach ($property in $depsProperty.Value.PSObject.Properties) {
            $entries += [pscustomobject]@{
                Name      = [string]$property.Name
                Spec      = [string]$property.Value
                Current   = ''
                Latest    = ''
                Status    = '待查询'
                Kind      = 'info'
                Selected  = $false
                SaveFlags = @('--save-exact')
            }
        }
    }

    if ($entries.Count -eq 0) {
        Write-Info '该 profile 没有任何 dependencies 条目，跳过。'
        return [pscustomobject]@{ Profile = $Profile; Updated = 0; Failed = 0; UpToDate = 0; Skipped = 0; Blocked = $false; Backup = $null; Empty = $true }
    }

    Write-Action '正在查询最新版本...'

    $queryTotal = 0
    $queryFailed = 0

    foreach ($entry in $entries) {
        if ($Only.Count -gt 0 -and -not (Test-NameMatch $entry.Name $Only)) {
            $entry.Status = '未选中'
            $entry.Kind = 'muted'
            continue
        }
        if (Test-NameMatch $entry.Name $Skip) {
            $entry.Status = '跳过(参数)'
            $entry.Kind = 'muted'
            continue
        }
        if (-not (Test-RegistrySpecifier $entry.Spec)) {
            $entry.Status = '跳过(非 registry)'
            $entry.Kind = 'muted'
            continue
        }
        if (-not $IncludeOfficial -and $entry.Name -like '@deepseek-ai/*') {
            $entry.Status = '跳过(官方包)'
            $entry.Kind = 'muted'
            continue
        }

        $installed = Get-InstalledVersion -ProfileDir $ProfileDir -Package $entry.Name
        $specVersion = Get-VersionFromSpecifier $entry.Spec
        $current = if ($installed) { $installed } elseif ($specVersion) { $specVersion } else { $entry.Spec }
        $entry.Current = [string]$current
        $entry.SaveFlags = @(Get-SaveFlags $entry.Spec)

        $queryTotal++
        try {
            $latest = Get-LatestVersion -Package $entry.Name -RegistryBase $RegistryBase
            $entry.Latest = $latest
            $comparison = Compare-DshVersion $latest $entry.Current
            if ($comparison -gt 0) {
                $entry.Status = '可更新'
                $entry.Kind = 'warn'
                $entry.Selected = $true
            } elseif ($comparison -eq 0) {
                $entry.Status = '已最新'
                $entry.Kind = 'muted'
            } else {
                $entry.Status = '本地版本更新'
                $entry.Kind = 'muted'
            }
        } catch {
            $queryFailed++
            $entry.Latest = '?'
            $entry.Status = '查询失败'
            $entry.Kind = 'error'
            Write-Warn ("{0}: {1}" -f $entry.Name, $_.Exception.Message)
        }
    }

    Write-Host ''
    Show-PluginTable -Entries $entries

    $selected = @($entries | Where-Object { $_.Selected })
    $upToDate = @($entries | Where-Object { $_.Status -eq '已最新' }).Count
    $skipped = @($entries | Where-Object { $_.Kind -eq 'muted' -and $_.Status -ne '已最新' }).Count

    Write-Host ''
    if ($queryFailed -gt 0) {
        Write-Warn ("{0} 个插件的版本查询失败，本次会跳过它们。" -f $queryFailed)
        if ($queryFailed -eq $queryTotal) { $script:Failed = $true }
    }

    if ($selected.Count -eq 0) {
        Write-Ok '没有需要更新的插件。'
        return [pscustomobject]@{ Profile = $Profile; Updated = 0; Failed = 0; UpToDate = $upToDate; Skipped = $skipped; Blocked = $false; Backup = $null }
    }

    Write-Info ("可更新 {0} 个，已是最新 {1} 个，跳过 {2} 个。" -f $selected.Count, $upToDate, $skipped)

    if ($DryRun) {
        Write-Action '以下命令将被执行（-DryRun 不会真正运行）：'
        foreach ($entry in $selected) {
            $preview = 'dsh plugin --profile {0} add {1}@{2} {3}' -f $Profile, $entry.Name, $entry.Latest, ($entry.SaveFlags -join ' ')
            Write-Host ('    ' + $preview.TrimEnd()) -ForegroundColor DarkCyan
        }
        return [pscustomobject]@{ Profile = $Profile; Updated = 0; Failed = 0; UpToDate = $upToDate; Skipped = $skipped; Blocked = $false; Backup = $null; DryRun = $true }
    }

    if ($Check) {
        return [pscustomobject]@{ Profile = $Profile; Updated = 0; Failed = 0; UpToDate = $upToDate; Skipped = $skipped; Blocked = $false; Backup = $null; Check = $true }
    }

    if (-not $CliPath) {
        throw '未找到 dsh CLI，无法执行更新；请用 -DshCli 指定 dsh.cmd 的路径。'
    }

    Assert-Writable -Profile $Profile -ProfileDir $ProfileDir

    if (-not $Yes) {
        Write-Host ''
        Write-Host ("  即将更新 {0} 个插件，是否继续? [y/N] " -f $selected.Count) -NoNewline -ForegroundColor Yellow
        $answer = ''
        try { $answer = Read-Host } catch { $answer = '' }
        if ($answer -notmatch '^(y|yes|是)$') {
            Write-Info '已取消，未做任何修改。'
            return [pscustomobject]@{ Profile = $Profile; Updated = 0; Failed = 0; UpToDate = $upToDate; Skipped = $skipped; Blocked = $false; Backup = $null; Cancelled = $true }
        }
    }

    $backup = $null
    if (-not $NoBackup) {
        $backup = New-ProfileBackup -Profile $Profile -ProfileDir $ProfileDir -Planned $selected
        Write-Info ("已备份   : {0}" -f $backup)
    }

    Write-Action ("开始更新 {0} 个插件..." -f $selected.Count)

    $updated = 0
    $failed = 0
    $index = 0

    foreach ($entry in $selected) {
        $index++
        Write-Host ''
        Write-Host ("[{0}/{1}] {2}  {3} -> {4}" -f $index, $selected.Count, $entry.Name, $entry.Current, $entry.Latest) -ForegroundColor Cyan

        $arguments = @('plugin', '--profile', $Profile, 'add', ("{0}@{1}" -f $entry.Name, $entry.Latest)) + @($entry.SaveFlags)
        & $CliPath @arguments
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            $installedNow = Get-InstalledVersion -ProfileDir $ProfileDir -Package $entry.Name
            if ($installedNow -and $installedNow -eq $entry.Latest) {
                Write-Ok ("完成：{0} {1}" -f $entry.Name, $installedNow)
                $entry.Current = $installedNow
                $entry.Status = '更新成功'
                $entry.Kind = 'ok'
                $updated++
            } else {
                $shown = if ($installedNow) { $installedNow } else { '未知' }
                Write-Warn ("命令执行成功，但读到的已安装版本是 {0}（预期 {1}）" -f $shown, $entry.Latest)
                if ($installedNow) { $entry.Current = $installedNow }
                $entry.Status = '版本未确认'
                $entry.Kind = 'warn'
                $updated++
            }
        } else {
            Write-Err ("更新失败（退出码 {0}）" -f $exitCode)
            $entry.Status = '更新失败'
            $entry.Kind = 'error'
            Write-FailureDetail -ProfileDir $ProfileDir
            $failed++
            if (-not $ContinueOnError) {
                Write-Warn '已停止后续更新（使用 -ContinueOnError 可继续）。'
                break
            }
        }
    }

    foreach ($entry in $entries) {
        if ($entry.Status -eq '可更新') {
            $entry.Status = '未处理'
            $entry.Kind = 'muted'
        }
    }

    Write-Host ''
    Show-PluginTable -Entries $entries

    Write-Host ''
    Write-Host '  结果' -ForegroundColor Cyan
    Write-Info ("成功 {0} / 失败 {1} / 已最新 {2} / 跳过 {3}" -f $updated, $failed, $upToDate, $skipped)
    if ($backup) { Write-Info ("备份     : {0}" -f $backup) }
    if ($updated -gt 0) {
        Write-Ok '如需让新版本生效，请重启 DeepSeek Harness。'
    }
    if ($failed -gt 0) {
        $script:Failed = $true
        if ($backup) {
            Write-Warn ('回滚命令 : .\Update-DshPlugins.ps1 -Restore "{0}"' -f $backup)
        }
    }

    return [pscustomobject]@{
        Profile  = $Profile
        Updated  = $updated
        Failed   = $failed
        UpToDate = $upToDate
        Skipped  = $skipped
        Blocked  = $false
        Backup   = $backup
    }
}


# ============================================================================
#  主流程
# ============================================================================

function Get-ModeText {
    if ($Restore) { return '回滚' }
    if ($Check) { return '检查（只读）' }
    if ($DryRun) { return '预演（只读）' }
    return '更新'
}

function Invoke-Main {
    $script:DshHome = Get-DshHome
    $env:DSH_HOME = $script:DshHome

    Write-Host ''
    Write-Host '  DSH 插件更新工具' -ForegroundColor Cyan
    Write-Host ('  ' + ('=' * 66)) -ForegroundColor DarkGray
    Write-Info ("DSH 主目录 : {0}" -f $script:DshHome)
    Write-Info ("操作模式   : {0}" -f (Get-ModeText))

    if ($Check -and $Restore) { throw '-Check 和 -Restore 不能同时使用。' }

    $script:Cli = Resolve-DshCli -Hint $DshCli

    if ($Restore) {
        if (-not $script:Cli) { throw '未找到 dsh CLI，无法回滚后重新安装；请用 -DshCli 指定 dsh.cmd 的路径。' }
        Write-Info ("DSH CLI    : {0}" -f $script:Cli)
        Invoke-RestoreAction -BackupInput $Restore -CliPath $script:Cli
        return $(if ($script:Failed) { 1 } else { 0 })
    }

    if ($script:Cli) {
        Write-Info ("DSH CLI    : {0}" -f $script:Cli)
        $versionOutput = @()
        try {
            $versionOutput = @(& $script:Cli --version 2>$null)
        } catch { }
        if ($LASTEXITCODE -eq 0 -and $versionOutput.Count -gt 0) {
            Write-Info ("DSH 版本   : {0}" -f ([string]$versionOutput[0]).Trim())
        }
    } elseif (-not ($Check -or $DryRun)) {
        throw '未找到 dsh CLI。请用 -DshCli 指定 dsh.cmd 的路径（通常在 <安装目录>\resources\runtime\cli\bin\dsh.cmd）。'
    } else {
        Write-Warn '未找到 dsh CLI，仅能查询版本；更新需要 -DshCli。'
    }

    $profilesRoot = Join-Path $script:DshHome 'profiles'
    if (-not (Test-Path -LiteralPath $profilesRoot)) {
        throw ("找不到 profile 目录：{0}。请先启动一次 DeepSeek Harness 完成初始化。" -f $profilesRoot)
    }

    $targets = @()
    if ($AllProfiles) {
        $targets = @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'package.json') } |
            Sort-Object @{ Expression = { if ($_.Name -eq 'desktop') { 0 } else { 1 } } }, Name |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName } })
        if ($targets.Count -eq 0) { throw ("{0} 下没有已初始化的 profile。" -f $profilesRoot) }
    } else {
        $profileDir = Join-Path $profilesRoot $ProfileName
        if (-not (Test-Path -LiteralPath (Join-Path $profileDir 'package.json'))) {
            throw ("profile '{0}' 尚未初始化（缺少 {1}）。" -f $ProfileName, (Join-Path $profileDir 'package.json'))
        }
        $targets = @([pscustomobject]@{ Name = $ProfileName; Path = $profileDir })
    }

    $summaries = @()
    foreach ($target in $targets) {
        Write-Host ''
        Write-Host ('-' * 70) -ForegroundColor DarkGray
        Write-Host ("  profile: {0}" -f $target.Name) -ForegroundColor Cyan
        Write-Info ("目录     : {0}" -f $target.Path)

        $apps = @(Get-DshAppProcesses)
        if ($apps.Count -gt 0 -and $target.Name -eq 'desktop') {
            Write-Warn ("DSH 桌面端正在运行（PID {0}）" -f (($apps | ForEach-Object { $_.Id }) -join ', '))
        }
        $lock = Get-ProfileLockState -ProfileDir $target.Path
        if ($lock.Exists) {
            if ($lock.Alive) {
                Write-Warn ("配置写入锁被 PID {0}（{1}）占用" -f $lock.HolderPid, $lock.ProcessName)
            } else {
                Write-Info ("配置锁 Holder PID {0} 已退出（下次写入时自动接管）" -f $lock.HolderPid)
            }
        }

        $registryBase = Get-RegistryForProfile -ProfileDir $target.Path
        Write-Info ("registry : {0}" -f $registryBase)

        try {
            $summaries += Invoke-ProfileUpdate -Profile $target.Name -ProfileDir $target.Path -RegistryBase $registryBase -CliPath $script:Cli
        } catch {
            Write-Err $_.Exception.Message
            $script:Blocked = $true
            $summaries += [pscustomobject]@{ Profile = $target.Name; Updated = 0; Failed = 0; UpToDate = 0; Skipped = 0; Blocked = $true; Backup = $null }
        }
    }

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    $totalUpdated = ($summaries | Measure-Object -Property Updated -Sum).Sum
    $totalFailed = ($summaries | Measure-Object -Property Failed -Sum).Sum
    if (-not $totalUpdated) { $totalUpdated = 0 }
    if (-not $totalFailed) { $totalFailed = 0 }

    if ($totalUpdated -gt 0) {
        Write-Ok ("本次共更新 {0} 个插件。重启 DeepSeek Harness 后生效。" -f $totalUpdated)
    } elseif ($script:Blocked) {
        Write-Warn '本次没有修改任何文件（前置检查未通过），处理完上面的问题后重新运行即可。'
    } elseif ($totalFailed -eq 0) {
        Write-Info '没有发生任何更新。'
    }

    if ($Restart -and $totalUpdated -gt 0) {
        $exe = Get-AppExeFromCli -CliPath $script:Cli
        $runningCount = @(Get-DshAppProcesses).Count
        if (-not $exe) {
            Write-Warn '未找到 DeepSeek Harness.exe，请手动启动。'
        } elseif ($runningCount -gt 0) {
            Write-Warn 'DSH 仍在运行，未自动启动。请手动重启。'
        } else {
            Write-Info '正在启动 DeepSeek Harness...'
            Start-Process -FilePath $exe
        }
    }

    if ($script:Failed) { return 1 }
    if ($script:Blocked) { return 2 }
    return 0
}


$script:ExitCode = 0
try {
    $script:ExitCode = Invoke-Main
} catch {
    Write-Err $_.Exception.Message
    $script:ExitCode = 2
} finally {
    if ($script:PrevConsoleEncoding) {
        try { [Console]::OutputEncoding = $script:PrevConsoleEncoding } catch { }
    }
}

exit $script:ExitCode
