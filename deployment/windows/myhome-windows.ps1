#requires -Version 5.1
<#
Windows 10/11 x64 一键部署包（联网 · 产物直跑）。v57 起从「源码直跑」改为「产物直跑」，与
myhome-unix.sh 逐条对齐：
  · 工具链只保留运行必需的 JDK 21 与 MySQL 8.4（+ 微软 VC++ 运行库），随包携带并逐一校验 SHA256，
    不联网下载。不再需要 git / Maven / pnpm / Node —— 应用不再现场编译，直接跑构建好的产物。
  · 应用产物（后端 fat JAR + 两份已构建前端 dist + schema 快照 + version.json）打包成一个 zip 随包
    携带于 runtime/。首次部署解到 <install>\app\，用 `java -jar` 起后端；后端单端口(8080)同时托管
    两份 dist（Topology A：/admin/** 出 B 端、/** 出 C 端），前后端同源、无需任何反向代理。
  · 数据库迁移（Flyway）随 JAR 的 classpath 一起发布，故「部署包的 SQL」= 重新构建 JAR 即自动更新。
    空库冷启动先载入构建期生成的 schema-snapshot.sql（含真 Flyway 历史），规避 V103 严格重放失败；
    已有库跳过快照，走后端启动时的 Flyway 增量迁移。
  · 「部署最新」（04-update.cmd 或后端部署管理页一键触发）从 GitHub Release 拉取最新产物包，校验
    SHA256 后原子替换 app\，再重启后端。这一步需要联网。
  · 私有 MySQL 监听 127.0.0.1:13306，数据落 <install>\data\mysql，绝不接管系统 MySQL。
  · 只绑定 127.0.0.1；不改防火墙/执行策略等机器级安全设置、不杀未知进程、不清库、不删密钥。
通过 .cmd 启动器运行（01-deploy.cmd / 02-start.cmd / 03-stop.cmd / 04-update.cmd）。
#>
[CmdletBinding()]
param(
    [ValidateSet('Deploy', 'Start', 'Stop', 'Update')][string]$Action = 'Deploy',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'MyHome')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8 = New-Object Text.UTF8Encoding($false)
$Root = $null
$State = $null
$Tools = $null
$Logs = $null
$MysqlData = $null
# 产物直跑只有两个端口：私有 MySQL(13306) 与后端(8080)。两份前端 dist 由后端单端口托管，不再各占端口。
$DbPort = 13306
$BackendPort = 8080
$Lock = $null
$Secrets = @{}
$ClientFile = $null
$InitFile = $null
$IniFile = $null
$Package = $null
$Runtime = $null
$ExitCode = 0
$CurrentStep = '检查系统和安装目录'
$DiagnosticFiles = @()
$RunLog = $null
# 应用产物目录（解包后的 JAR + 两份 dist + schema 快照 + version.json）；更新时整目录原子替换。
$AppDir = $null
$AppNew = $null
$AppOld = $null
$AppVersionFile = $null
# 清单里 app / update 段的值（Load-AppManifest 填充）。
$AppZipName = 'MyHome-app-payload.zip'
$AppJarName = 'family-home-server.jar'
$AppAdminDirName = 'admin'
$AppH5DirName = 'h5'
$AppSnapshotName = 'schema-snapshot.sql'
$UpdateRepo = ''
$UpdateVersionAsset = 'version.json'
$UpdatePayloadAsset = 'MyHome-app-payload.zip'
# 当前解包在 app\ 里的产物元数据（Read-AppMeta 从 app\version.json 读取）。
$AppVersion = ''
$AppSalt = ''
$AppServerCommit = ''
$AppWebCommit = ''
# 最新发布版本元数据（Fetch-LatestRelease 从 GitHub Release 的 version.json 读取）。
$LatestVersion = ''
$LatestSha = ''
$LatestServerCommit = ''
$LatestWebCommit = ''
# 「部署最新」进度上报：仅 Action=Update 时启用。后端点一下 → deploy-now.cmd 分离拉起本脚本 →
# 每个 Set-Step 实时把进度写进 logs/deploy-status.json（原子写），前端轮询它显示进度；
# Update 会杀掉并重启后端，故进度必须落盘，重启后的新后端读同一个文件接着显示。
$DeployActive = $false
$DeployStatusPath = $null
$DeployHistoryPath = $null
$DeployRunId = $null
$DeployStartedAt = $null
$DeployPhase = ''
$DeployLines = $null
$DeployFromVersion = ''
$DeployTargetVersion = ''
$DeployResultVersion = ''
$DeployFromCommits = @{}
$DeployTargetCommits = @{}
$DeployResultCommits = @{}

function Protect-Text([string]$Text) {
    # Normalize terminal escapes BEFORE redaction: styling can split a secret in two.
    # Never print ErrorRecord/source lines, environment dumps, SQL or credential files.
    $Text = [regex]::Replace($Text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
    $Text = [regex]::Replace($Text, '\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)', '')
    $Text = [regex]::Replace($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    foreach ($value in $script:Secrets.Values) {
        if (![string]::IsNullOrEmpty($value)) { $Text = $Text.Replace($value, '[REDACTED]') }
    }
    $Text = [regex]::Replace($Text, 'pbkdf2_sha256\$\d+\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+', '[REDACTED_HASH]')
    $Text = [regex]::Replace($Text, '(?i)(Bearer\s+)\S+', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '(?im)((?:Authorization|Cookie)\s*:\s*)[^\r\n]*', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '(?i)(https?://)[^\s/@]+:[^\s/@]+@', '$1[REDACTED]@')
    $Text = [regex]::Replace($Text, '(?i)(https?://[^\s?]+)\?[^\s]*', '$1?[REDACTED]')
    $Text = [regex]::Replace($Text, '(?i)((?:[\w.-]*(?:password|passwd|secret|token|salt)|authorization|cookie|ticket)["'']?\s*[=:]\s*)(?:"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|[^\s,;]+)', '$1[REDACTED]')
    # Startup errors may echo SQL. Keep the error code/reason, not statement payloads.
    $Text = [regex]::Replace($Text, '(?im)^.*(?:Statement\s*:|\b(?:INSERT\s+INTO|UPDATE\s+\w+\s+SET|ALTER\s+USER|IDENTIFIED\s+BY)\b).*(?:\r?\n|$)', '[SQL 内容已隐藏]' + "`n")
    return $Text
}
function Write-Diagnostic([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    $safe = Protect-Text $Message
    Write-Host $safe -ForegroundColor $Color
    if ($script:RunLog) {
        try { [IO.File]::AppendAllText($script:RunLog, $safe + "`r`n", $script:Utf8) }
        catch {
            $script:RunLog = $null
            Write-Host ('[日志写入失败] ' + (Protect-Text $_.Exception.Message) + '；请保留窗口截图。') -ForegroundColor Yellow
        }
    }
}
function Info([string]$Message) { Write-Diagnostic "[MyHome] $Message" Cyan }
function Set-Step([string]$Name, [string[]]$Files = @()) {
    $script:CurrentStep = $Name
    $script:DiagnosticFiles = $Files
    Info "步骤：$Name"
    if ($script:DeployActive) { $script:DeployPhase = $Name; Add-DeployLine "步骤：$Name" }
}
function Error-Reason($Failure) {
    $exception = $Failure.Exception
    $messages = New-Object 'System.Collections.Generic.List[string]'
    while ($exception) {
        if ($exception.Message -and !$messages.Contains($exception.Message)) { $messages.Add($exception.Message) }
        $exception = $exception.InnerException
    }
    return (Protect-Text ($messages -join ' -> '))
}
function Show-Failure($Failure) {
    Write-Diagnostic "`n[失败步骤] $script:CurrentStep" Red
    Write-Diagnostic ('[失败原因] ' + (Error-Reason $Failure)) Red
    if ($Failure.InvocationInfo -and $Failure.InvocationInfo.ScriptLineNumber -gt 0) {
        Write-Diagnostic ("[脚本位置] myhome-windows.ps1 第 {0} 行" -f $Failure.InvocationInfo.ScriptLineNumber)
    }
    foreach ($file in $script:DiagnosticFiles) {
        Write-Diagnostic "[相关日志] $file"
        try {
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                # Boot's failure description is on the lines AFTER the heading.
                # Keep bounded context, not a dump of request logs or SQL statements.
                $selected = New-Object 'System.Collections.Generic.List[string]'
                $contextLines = 0
                foreach ($line in @(Get-Content -LiteralPath $file -Encoding UTF8 -Tail 100 -ErrorAction Stop)) {
                    if ($line -match '(?i)^\s*Statement\s*:') { $contextLines = 0; continue }
                    if ($line -match '(?i)^\s*(Description|Reason|Action)\s*:') {
                        $selected.Add($line)
                        $contextLines = 6
                    } elseif ($contextLines -gt 0) {
                        $selected.Add($line)
                        $contextLines--
                    } elseif ($line -match '(?i)\bERROR\b|Caused by:|Exception:|APPLICATION FAILED|^\s*(SQL State|Error Code|Message)\s*:') {
                        $selected.Add($line)
                    }
                }
                foreach ($line in @($selected | Select-Object -Last 20)) { Write-Diagnostic ('  ' + $line) Yellow }
            }
        } catch { Write-Diagnostic ('[日志读取失败] ' + (Error-Reason $_)) Yellow }
    }
    if ($script:RunLog) { Write-Diagnostic "[本次操作记录] $script:RunLog" }
    else { Write-Diagnostic '[本次操作记录] 尚未创建或无法写入，请复制上述原因或截图。' }
    Write-Diagnostic '请保留 data/ 和 state/；不要删库、删密钥或重新初始化来重试。'
    $launcher = @{ Deploy = '01-deploy.cmd'; Start = '02-start.cmd'; Stop = '03-stop.cmd'; Update = '04-update.cmd' }[$script:Action]
    Write-Diagnostic "修复上述原因后，重新运行 $launcher（自定义安装目录需使用相同参数）。"
}
function Save-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $script:Utf8) }
function Save-Json([string]$Path, $Value) {
    $tmp = "$Path.tmp"
    Save-Text $tmp ($Value | ConvertTo-Json -Depth 8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Initialize-DeployStatus {
    # 后端点火时已写过一份带 targetVersion/targetCommits 的初始 deploy-status.json；这里接管它、保留目标，
    # runId 沿用后端注入的 FH_DEPLOY_RUN_ID（手动 04-update.cmd 没有就现生成一个）。
    $script:DeployRunId = if ($env:FH_DEPLOY_RUN_ID) { $env:FH_DEPLOY_RUN_ID } else { [guid]::NewGuid().ToString() }
    $script:DeployStatusPath = Join-Path $Logs 'deploy-status.json'
    # 部署历史：本次跑到终态时把整条状态前插进这个数组文件，供后端 /deploy/history 只读回吐给超管。
    $script:DeployHistoryPath = Join-Path $Logs 'deploy-history.json'
    $script:DeployTargetCommits = @{}
    $script:DeployTargetVersion = ''
    if (Test-Path -LiteralPath $script:DeployStatusPath) {
        try {
            $existing = Get-Content -LiteralPath $script:DeployStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing -and $existing.targetCommits) { $script:DeployTargetCommits = $existing.targetCommits }
            if ($existing -and $existing.targetVersion) { $script:DeployTargetVersion = [string]$existing.targetVersion }
        } catch { }
    }
    $script:DeployStartedAt = [DateTime]::UtcNow.ToString('o')
    $script:DeployPhase = '开始部署最新版本'
    $script:DeployLines = New-Object 'System.Collections.Generic.List[object]'
    # fromVersion/fromCommits（本次部署前 app\version.json 的值）在 Update 替换产物前才抓，见 Run-Update。
    $script:DeployFromVersion = ''
    $script:DeployFromCommits = @{}
    $script:DeployResultVersion = ''
    $script:DeployResultCommits = @{}
    $script:DeployActive = $true
    Add-DeployLine '部署脚本已启动：从 GitHub Release 拉取最新产物包 + 重启后端'
}
function Add-DeployLine([string]$Message, [string]$Level = 'info') {
    if (!$script:DeployActive) { return }
    $script:DeployLines.Add(@{ ts = [DateTime]::UtcNow.ToString('o'); message = (Protect-Text $Message); level = $Level })
    Write-DeployStatus 'running'
}
function Write-DeployStatus([string]$Status, [string]$ErrorMessage = '') {
    if (!$script:DeployActive -or !$script:DeployStatusPath) { return }
    $obj = [ordered]@{
        runId = $script:DeployRunId
        status = $Status
        phase = $script:DeployPhase
        startedAt = $script:DeployStartedAt
        finishedAt = $(if ($Status -eq 'running') { $null } else { [DateTime]::UtcNow.ToString('o') })
        error = $(if ($ErrorMessage) { $ErrorMessage } else { $null })
        fromVersion = $script:DeployFromVersion
        targetVersion = $script:DeployTargetVersion
        resultVersion = $script:DeployResultVersion
        fromCommits = $script:DeployFromCommits
        targetCommits = $script:DeployTargetCommits
        resultCommits = $script:DeployResultCommits
        lines = $script:DeployLines
    }
    # 进度写失败绝不能拖垮部署本身；忽略即可（前端大不了少看到一行）。
    try { Save-Json $script:DeployStatusPath $obj } catch { }
    # 终态才入历史：一次部署只应落一条，按 runId 去重后前插，最多留 50 条。
    if ($Status -ne 'running') { try { Append-DeployHistory $obj } catch { } }
}
function Append-DeployHistory($Record) {
    if (!$script:DeployHistoryPath) { return }
    $history = @()
    if (Test-Path -LiteralPath $script:DeployHistoryPath) {
        try {
            $existing = Get-Content -LiteralPath $script:DeployHistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing) { $history = @($existing) }
        } catch { $history = @() }
    }
    # 同一 runId 只保留最新这一条（重复触发终态时不堆叠），新记录排在最前。
    $runId = $Record.runId
    $rest = @($history | Where-Object { $_.runId -ne $runId })
    $merged = @($Record) + $rest
    if ($merged.Count -gt 50) { $merged = $merged[0..49] }
    $tmp = "$($script:DeployHistoryPath).tmp"
    # 必须用 -InputObject：管道形式会把「只有一条」的数组拆成裸对象，后端 isArray() 就判否、历史变空。
    Save-Text $tmp (ConvertTo-Json -InputObject $merged -Depth 8)
    Move-Item -LiteralPath $tmp -Destination $script:DeployHistoryPath -Force
}
function Check-Hash([string]$Path, [string]$Expected, [string]$Algorithm = 'SHA256') {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ((Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash -eq $Expected)
}
function Get-SafePath([string]$Base, [string]$Relative) {
    # Reject Win32 aliases/ADS as well as traversal; ZIP entries are never trusted paths.
    $relativePath = $Relative.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -match '^[\/]|[:<>"|?*\x00-\x1F]') {
        throw "安装包含不安全路径：$Relative"
    }
    foreach ($part in $relativePath.Split('/')) {
        if (!$part -or $part -eq '.' -or $part -eq '..' -or $part -match '[. ]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "安装包含不安全路径：$Relative"
        }
    }
    $prefix = [IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath((Join-Path $Base $relativePath))
    if (!$target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "安装包路径越界：$Relative" }
    return $target
}
function Get-LocalPackage($Spec, [string]$Directory = 'runtime') {
    if ($Spec.algorithm -cne 'SHA256' -or $Spec.hash -notmatch '^[a-fA-F0-9]{64}$') {
        throw '一键部署包清单必须提供有效的 SHA256；请重新完整拷贝一键部署包。'
    }
    if ($Directory -eq 'runtime' -and $Spec.file -match '[\\/]') { throw 'runtime 清单的 file 必须为文件名，不能包含目录。' }
    $relative = [string]$Spec.file
    if ($Directory) { $relative = $Directory + '/' + $relative }
    $file = Get-SafePath $PSScriptRoot $relative
    Set-Step "校验本地文件 $relative"
    if (!(Check-Hash $file $Spec.hash $Spec.algorithm)) {
        throw "本地文件缺失或 SHA256 不符：$relative。请重新完整拷贝一键部署包（包含 runtime/）；不联网下载。"
    }
    return $file
}
function Expand-CheckedZip([string]$Zip, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    $seen = @{}
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/').TrimEnd('/')
            $target = Get-SafePath $Destination $name
            if ($seen.ContainsKey($target)) { throw "ZIP 含重复路径或大小写别名：$name" }
            $seen[$target] = $true
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400) -ne 0) {
                throw "ZIP 不允许符号链接或重解析点：$name"
            }
        }
    } finally { $archive.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Destination)
}
function Install-Zip($Spec, [string]$Name, [string]$Probe) {
    $zip = Get-LocalPackage $Spec
    Set-Step "检查 $Name 运行环境"
    $runtimeHome = Join-Path $Tools $Name
    $stamp = Join-Path $runtimeHome '.package-hash'
    if ((Test-Path -LiteralPath $stamp) -and (Test-Path -LiteralPath (Join-Path $runtimeHome $Probe))) {
        if (([IO.File]::ReadAllText($stamp)).Trim() -ne $Spec.hash) { throw "Installed $Name differs from this package. Do not replace runtimes over a running database." }
        return $runtimeHome
    }
    Set-Step "解压并安装 $Name"
    $staging = Join-Path $Tools ($Name + '.extract')
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Expand-CheckedZip $zip $staging
    # 归档把内容平铺在根（directory 为空）时，staging 本身即顶层。
    $top = if ([string]::IsNullOrEmpty($Spec.directory)) { $staging } else { Get-SafePath $staging $Spec.directory }
    if (!(Test-Path -LiteralPath (Join-Path $top $Probe))) { throw "Incomplete $Name archive." }
    if (Test-Path -LiteralPath $runtimeHome) { throw "Incomplete runtime directory: $runtimeHome . Keep data/state; remove only this incomplete tools directory and retry." }
    Move-Item -LiteralPath $top -Destination $runtimeHome
    Save-Text $stamp $Spec.hash
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    return $runtimeHome
}
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    if (!(Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "Executable not found: $Exe" }
    $recent = New-Object 'System.Collections.Generic.Queue[string]'
    $oldPreference = $ErrorActionPreference
    $nativeExit = 0
    $invocationReason = $null
    try {
        # PS 5.1 wraps redirected native stderr in ErrorRecord. Do not abort on warnings.
        $ErrorActionPreference = 'Continue'
        & $Exe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -notlike 'NativeCommandError*') {
                $invocationReason = Error-Reason $_
            }
            $line = Protect-Text ([string]$_)
            Write-Diagnostic $line
            $recent.Enqueue($line)
            if ($recent.Count -gt 12) { [void]$recent.Dequeue() }
        }
        $nativeExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($invocationReason) { throw "无法执行 $([IO.Path]::GetFileName($Exe))：$invocationReason" }
    if ($nativeExit -ne 0) {
        throw ("{0} 执行失败，退出码 {1}。最后输出：`n{2}" -f [IO.Path]::GetFileName($Exe), $nativeExit, ($recent.ToArray() -join "`n"))
    }
}
function Quote-Arg([string]$Value) {
    # Windows CommandLineToArgvW quoting; includes paths containing spaces/Chinese.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Join-Args([string[]]$Values) { return (($Values | ForEach-Object { Quote-Arg $_ }) -join ' ') }
function Assert-PortFree([int]$Port) {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() } catch { throw "无法监听本机端口 $Port，可能被占用或没有权限：$(Error-Reason $_)。不会结束其他软件的进程。" }
    finally { $listener.Stop() }
}
function Owned-Process([string]$Name) {
    $file = Join-Path $State ($Name + '.pid.json')
    if (!(Test-Path -LiteralPath $file)) { return $null }
    $record = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $p = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
    if (!$p) { Remove-Item -LiteralPath $file -Force; return $null }
    if (($p.Path -ne $record.path) -or ($p.StartTime.ToUniversalTime().Ticks.ToString() -ne $record.started)) {
        throw "Stale PID record for $Name; refusing to stop or adopt another process. Verify it, then remove $file."
    }
    return $p
}
function Start-Owned([string]$Name, [string]$Exe, [string[]]$Arguments, [string]$WorkingDir = $Root) {
    $old = Owned-Process $Name
    if ($old) { return $old }
    foreach ($suffix in @('out', 'err')) {
        $log = Join-Path $Logs "$Name.$suffix.log"
        if (Test-Path -LiteralPath $log) {
            Move-Item -LiteralPath $log -Destination "$log.$([DateTime]::Now.ToString('yyyyMMddHHmmssfff'))"
        }
    }
    $p = Start-Process -FilePath $Exe -ArgumentList (Join-Args $Arguments) -WorkingDirectory $WorkingDir -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Logs "$Name.out.log") -RedirectStandardError (Join-Path $Logs "$Name.err.log")
    $p.Refresh()
    if ($p.HasExited) { throw "$Name 启动后立即退出，退出码 $($p.ExitCode)。" }
    try {
        Save-Json (Join-Path $State "$Name.pid.json") @{ pid = $p.Id; path = $p.Path; started = $p.StartTime.ToUniversalTime().Ticks.ToString() }
    } catch {
        $recordReason = Error-Reason $_
        # Roll back only the process just created here; never search/kill by port or name.
        if ($Name -eq 'mysql') {
            try { Invoke-Native (Join-Path $Runtime.mysql 'bin\mysqladmin.exe') @("--defaults-extra-file=$ClientFile", '--connect-timeout=5', '--wait=5', 'shutdown') } catch { }
            $p.Refresh()
            if (!$p.HasExited) { throw "Cannot save the MySQL PID record: $recordReason. Owned PID $($p.Id) may still be starting; keep data/state and get help before retrying. No database process was force-killed." }
        } else {
            $p.Refresh()
            if (!$p.HasExited) { $p.Kill(); [void]$p.WaitForExit(30000) }
        }
        throw "Cannot save the process record; startup was rolled back. $recordReason"
    }
    return $p
}
function Stop-Owned([string]$Name) {
    Set-Step "停止 $Name 服务" @((Join-Path $Logs "$Name.err.log"), (Join-Path $Logs "$Name.out.log"))
    $p = Owned-Process $Name
    if (!$p) { return }
    Info "Stopping $Name ..."
    # 产物直跑下 backend 就是 java.exe 本身（无 mvn/node 中间层）；taskkill /T 终止这个已校验 PID 的整棵树。
    # MySQL 不走这里（用 mysqladmin 优雅关闭）。只动这个 PID，绝不按端口/名字搜杀。
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    try { Invoke-Native $taskkill @('/PID', "$($p.Id)", '/T', '/F') } catch { }
    if (!$p.WaitForExit(30000)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        if (!$p.WaitForExit(10000)) { throw "$Name did not stop. No other processes were touched." }
    }
    Remove-Item -LiteralPath (Join-Path $State "$Name.pid.json") -Force
}
function Secure-State {
    # Private installer files only; never alter machine-wide execution policy/firewall.
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($sid, (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $State -AclObject $acl
}
function Random-Base64([int]$Length) {
    $bytes = New-Object byte[] $Length
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes); return [Convert]::ToBase64String($bytes) } finally { $rng.Dispose() }
}
function Load-Secrets {
    # 产物直跑下传输盐是随 dist 烘焙的固定公开值（见 Read-AppMeta），不再是逐安装随机的密钥，
    # 故这里只生成/保管 DbRoot/DbApp/Vault/Auth 四把真随机密钥（旧安装残留的 Transport 项忽略即可）。
    $path = Join-Path $State 'secrets.xml'
    if (!(Test-Path -LiteralPath $path)) {
        if ((Test-Path -LiteralPath (Join-Path $MysqlData 'mysql')) -or (Test-Path -LiteralPath (Join-Path $State 'installed.json'))) {
            throw 'Secrets are missing from an existing install. Restore state/secrets.xml; never regenerate the vault key over existing data.'
        }
        $initial = @{
            DbRoot = (Random-Base64 36); DbApp = (Random-Base64 36)
            Vault = (Random-Base64 32); Auth = (Random-Base64 48)
        }
        $encrypted = @{}
        foreach ($key in $initial.Keys) { $encrypted[$key] = ConvertTo-SecureString $initial[$key] -AsPlainText -Force }
        $encrypted | Export-Clixml -LiteralPath "$path.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$path.tmp" -Destination $path
    }
    try {
        $saved = Import-Clixml -LiteralPath $path
        foreach ($key in @('DbRoot', 'DbApp', 'Vault', 'Auth')) {
            if (!($saved[$key] -is [Security.SecureString])) { throw 'Invalid secure value.' }
            $credential = New-Object Net.NetworkCredential('', $saved[$key])
            $script:Secrets[$key] = $credential.Password
            if ([string]::IsNullOrWhiteSpace($script:Secrets[$key])) { throw 'Empty secret.' }
        }
    } catch { throw "无法解密安装凭据：$(Error-Reason $_)。请使用原电脑上的原 Windows 账号，不要删除 state/secrets.xml。" }
}
function Ensure-VcRuntime {
    # Fixed digest from Microsoft's official distribution, not a rolling download.
    # Do not invoke Authenticode/CRL lookup in the offline bootstrap; UAC still shows the publisher.
    if ($Package.vcredist.hash -ne 'cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b') {
        throw 'VC++ 清单不是固定的微软官方 SHA256；请重新完整拷贝一键部署包。'
    }
    $file = Get-LocalPackage $Package.vcredist
    Set-Step '检查微软 VC++ 运行库'
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
    if ($reg -and $reg.Installed -eq 1 -and ([version]$reg.Version.TrimStart('v')) -ge [version]'14.40.33810.0') { return }
    Info '使用包内微软 VC++ 安装程序（已校验固定 SHA256）；UAC 仍展示发布者，请确认 Microsoft Corporation。'
    Set-Step '安装微软 VC++ 运行库（管理员确认）'
    $p = Start-Process -FilePath $file -ArgumentList '/install /passive /norestart' -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -eq 3010 -or $p.ExitCode -eq 1641) { throw 'VC++ runtime installed. Restart Windows, then double-click 01-deploy.cmd again.' }
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 1638) { throw "VC++ installation failed ($($p.ExitCode)). Administrator approval is needed only for this runtime." }
}

# =============================================================================
# 应用产物：清单 / 解包 / 读取元数据 / 从 GitHub Release 拉取最新
# =============================================================================
function Load-AppManifest {
    # 从 packages.json 读 app / update 段（格式校验在主流程里针对 deploy/update 做）。
    if (!$Package) { return }
    if ($Package.app.file) { $script:AppZipName = [string]$Package.app.file }
    if ($Package.app.jar) { $script:AppJarName = [string]$Package.app.jar }
    if ($Package.app.adminDir) { $script:AppAdminDirName = [string]$Package.app.adminDir }
    if ($Package.app.h5Dir) { $script:AppH5DirName = [string]$Package.app.h5Dir }
    if ($Package.update.repo) { $script:UpdateRepo = [string]$Package.update.repo }
    if ($Package.update.versionAsset) { $script:UpdateVersionAsset = [string]$Package.update.versionAsset }
    if ($Package.update.payloadAsset) { $script:UpdatePayloadAsset = [string]$Package.update.payloadAsset }
}
function Extract-App([string]$Zip, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-CheckedZip $Zip $Destination
    if (!(Test-Path -LiteralPath (Join-Path $Destination $AppJarName) -PathType Leaf)) { throw "产物包缺少 $AppJarName；产物包不完整或结构不符。" }
    if (!(Test-Path -LiteralPath (Join-Path $Destination (Join-Path $AppAdminDirName 'index.html')) -PathType Leaf)) { throw "产物包缺少 $AppAdminDirName\index.html（B 端 dist）。" }
    if (!(Test-Path -LiteralPath (Join-Path $Destination (Join-Path $AppH5DirName 'index.html')) -PathType Leaf)) { throw "产物包缺少 $AppH5DirName\index.html（C 端 dist）。" }
    if (!(Test-Path -LiteralPath (Join-Path $Destination 'version.json') -PathType Leaf)) { throw '产物包缺少 version.json；无法确定版本与传输盐。' }
}
function Read-AppMeta {
    # 从当前 app\version.json 读取版本 / 传输盐 / 两仓 commit。
    if (!(Test-Path -LiteralPath $AppVersionFile -PathType Leaf)) { throw "应用目录缺少 version.json（$AppVersionFile）；请重新运行 01-deploy.cmd。" }
    $meta = Get-Content -LiteralPath $AppVersionFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:AppVersion = [string]$meta.version
    $script:AppSalt = [string]$meta.transportSalt
    $script:AppServerCommit = [string]$meta.server.commit
    $script:AppWebCommit = [string]$meta.web.commit
    if ([string]::IsNullOrEmpty($script:AppVersion)) { throw 'app/version.json 缺少 version 字段。' }
    # 传输盐是随 dist 构建期烘焙的固定公开值（32 位十六进制）；后端运行时必须用同一个值，否则全站登录解密失败。
    if ($script:AppSalt -notmatch '^[a-fA-F0-9]{32}$') { throw 'app/version.json 的 transportSalt 不是 32 位十六进制；产物包损坏或与 dist 不同源。' }
}
function Install-App {
    # 首次部署：解包随包携带的产物 zip 到 app\。
    $zip = Get-LocalPackage $Package.app
    Set-Step '解包应用产物（后端 JAR + 两份前端 dist）'
    Extract-App $zip $AppDir
    Read-AppMeta
    Info "已就位应用版本：$AppVersion"
}
function Write-Installed([string]$Version, [string]$ServerCommit, [string]$WebCommit, [string]$InstalledAt, [string]$UpdatedAt) {
    $record = [ordered]@{
        formatVersion = 4; offline = $false; runMode = 'artifact'
        version = $Version
        server = @{ commit = $ServerCommit }
        web = @{ commit = $WebCommit }
        installedAt = $InstalledAt
    }
    if ($UpdatedAt) { $record.updatedAt = $UpdatedAt }
    Save-Json (Join-Path $State 'installed.json') $record
}
function Get-ReleaseUrl([string]$Asset) { return "https://github.com/$UpdateRepo/releases/latest/download/$Asset" }
function Fetch-LatestRelease {
    # 拉取 GitHub 最新 Release 的 version.json（走稳定重定向，无需解析 Release API）。
    if ($UpdateRepo -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') { throw '清单 update.repo 不合法（应为 owner/name）；请重新完整拷贝一键部署包。' }
    Set-Step "查询 GitHub 最新发布版本（$UpdateRepo）"
    $vurl = Get-ReleaseUrl $UpdateVersionAsset
    $tmpv = Join-Path $State 'latest-version.json'
    if (Test-Path -LiteralPath $tmpv) { Remove-Item -LiteralPath $tmpv -Force }
    try { Invoke-WebRequest -UseBasicParsing -Uri $vurl -OutFile $tmpv -TimeoutSec 60 }
    catch { throw "无法获取最新发布版本信息（$vurl）；请检查网络，或确认该仓库已发布带 $UpdateVersionAsset 资产的 Release。$(Error-Reason $_)" }
    $meta = Get-Content -LiteralPath $tmpv -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:LatestVersion = [string]$meta.version
    $script:LatestSha = [string]$meta.payload.sha256
    $script:LatestServerCommit = [string]$meta.server.commit
    $script:LatestWebCommit = [string]$meta.web.commit
    if ([string]::IsNullOrEmpty($script:LatestVersion)) { throw '最新发布的 version.json 缺少 version 字段。' }
    if ($script:LatestSha -notmatch '^[a-fA-F0-9]{64}$') { throw '最新发布的 version.json 缺少有效的 payload.sha256；拒绝下载来源不明的产物包。' }
    Info "最新发布版本：$LatestVersion（当前运行：$AppVersion）"
}
function Download-ReleasePayload {
    # 下载并校验最新产物包到 state\download-payload.zip（校验通过前绝不触碰 app\）。
    Set-Step "下载最新产物包（$UpdatePayloadAsset）"
    $purl = Get-ReleaseUrl $UpdatePayloadAsset
    $tmpzip = Join-Path $State 'download-payload.zip'
    if (Test-Path -LiteralPath $tmpzip) { Remove-Item -LiteralPath $tmpzip -Force }
    try { Invoke-WebRequest -UseBasicParsing -Uri $purl -OutFile $tmpzip -TimeoutSec 1800 }
    catch { throw "下载最新产物包失败（$purl）；请检查网络后重试。现有应用未改动。$(Error-Reason $_)" }
    Set-Step '校验产物包 SHA256'
    $actual = (Get-FileHash -LiteralPath $tmpzip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $LatestSha.ToLowerInvariant()) { throw "下载的产物包 SHA256（$actual）与 version.json 声明的（$LatestSha）不符；已丢弃，现有应用未改动。" }
    return $tmpzip
}
function Swap-App([string]$NewDir) {
    # 原子替换 app\（调用前后端必须已停止）。
    if (Test-Path -LiteralPath $AppOld) { Remove-Item -LiteralPath $AppOld -Recurse -Force }
    if (Test-Path -LiteralPath $AppDir) { Move-Item -LiteralPath $AppDir -Destination $AppOld }
    Move-Item -LiteralPath $NewDir -Destination $AppDir
    if (Test-Path -LiteralPath $AppOld) { Remove-Item -LiteralPath $AppOld -Recurse -Force }
}
function Run-Update {
    # 「部署最新」的完整下载-校验-替换流程（不含停/起后端，由主流程编排）。返回 $true=已替换，$false=已是最新。
    Read-AppMeta
    $script:DeployFromCommits = @{ server = $AppServerCommit; web = $AppWebCommit }
    $script:DeployFromVersion = $AppVersion
    Add-DeployLine "当前运行版本：$AppVersion"
    Fetch-LatestRelease
    $script:DeployTargetCommits = @{ server = $LatestServerCommit; web = $LatestWebCommit }
    $script:DeployTargetVersion = $LatestVersion
    if ($LatestVersion -eq $AppVersion) {
        Add-DeployLine "已是最新版本（$AppVersion），无需替换产物"
        $script:DeployResultVersion = $AppVersion
        $script:DeployResultCommits = @{ server = $AppServerCommit; web = $AppWebCommit }
        return $false
    }
    Add-DeployLine "发现新版本：$AppVersion → $LatestVersion，开始下载"
    $zip = Download-ReleasePayload
    Set-Step '解包新版本到暂存目录并原子替换'
    if (Test-Path -LiteralPath $AppNew) { Remove-Item -LiteralPath $AppNew -Recurse -Force }
    Extract-App $zip $AppNew
    Swap-App $AppNew
    foreach ($f in @('download-payload.zip', 'latest-version.json')) {
        $p = Join-Path $State $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    Read-AppMeta
    $script:DeployResultVersion = $AppVersion
    $script:DeployResultCommits = @{ server = $AppServerCommit; web = $AppWebCommit }
    $iat = [DateTime]::UtcNow.ToString('o')
    $installedFile = Join-Path $State 'installed.json'
    if (Test-Path -LiteralPath $installedFile) {
        try { $existingIat = (Get-Content -LiteralPath $installedFile -Raw -Encoding UTF8 | ConvertFrom-Json).installedAt; if ($existingIat) { $iat = [string]$existingIat } } catch { }
    }
    Set-Step '记录本次更新的产物版本'
    Write-Installed $AppVersion $AppServerCommit $AppWebCommit $iat ([DateTime]::UtcNow.ToString('o'))
    $shortServer = if ($AppServerCommit.Length -ge 7) { $AppServerCommit.Substring(0, 7) } else { $AppServerCommit }
    $shortWeb = if ($AppWebCommit.Length -ge 7) { $AppWebCommit.Substring(0, 7) } else { $AppWebCommit }
    Add-DeployLine "已切换到新版本：$AppVersion（后端 $shortServer、前端 $shortWeb）"
    return $true
}

# =============================================================================
# MySQL
# =============================================================================
function Write-MysqlConfig {
    $base = $Runtime.mysql.Replace('\', '/')
    $data = $MysqlData.Replace('\', '/')
    $errorLog = (Join-Path $Logs 'mysql-error.log').Replace('\', '/')
    Save-Text $IniFile @"
[mysqld]
basedir="$base"
datadir="$data"
port=$DbPort
bind-address=127.0.0.1
mysqlx=0
character-set-server=utf8mb4
collation-server=utf8mb4_0900_ai_ci
max_allowed_packet=64M
innodb_buffer_pool_size=128M
skip-log-bin
general_log=OFF
log-error="$errorLog"
"@
    Save-Text $ClientFile @"
[client]
user=root
password="$($Secrets.DbRoot)"
host=127.0.0.1
port=$DbPort
protocol=TCP
default-character-set=utf8mb4
"@
}
function Sql([string]$Statement) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Runtime.mysql 'bin\mysql.exe'
    $psi.Arguments = Join-Args @("--defaults-extra-file=$ClientFile", '--batch', '--skip-column-names', '--connect-timeout=5')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # StandardInputEncoding does not exist in Windows PowerShell's .NET Framework.
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        $inputFailure = $null
        try {
            $inputBytes = $script:Utf8.GetBytes($Statement + "`n")
            $p.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $p.StandardInput.BaseStream.Flush()
        } catch { $inputFailure = Error-Reason $_ }
        finally {
            try { $p.StandardInput.Close() }
            catch { if (!$inputFailure) { $inputFailure = Error-Reason $_ } }
        }
        # An early mysql.exe exit can close stdin. Still collect stderr before failing.
        $timedOut = !$p.WaitForExit(60000)
        if ($timedOut) { $p.Kill(); [void]$p.WaitForExit(5000) }
        $errorText = '未能及时读取 MySQL 错误输出。'
        if ($stderr.Wait(5000)) { $errorText = Protect-Text ($stderr.GetAwaiter().GetResult()) }
        if ($timedOut) { throw "MySQL 客户端等待 60 秒后超时。$errorText" }
        if ($p.ExitCode -ne 0) { throw "MySQL 命令失败，退出码 $($p.ExitCode)：$errorText" }
        if ($inputFailure) { throw "MySQL 输入管道失败：$inputFailure。$errorText" }
        if (!$stdout.Wait(5000)) { throw 'MySQL 命令已退出，但读取结果超时。' }
        return $stdout.GetAwaiter().GetResult().Trim()
    } finally { $p.Dispose() }
}
function Import-SqlFile([string]$File) {
    # 把一个 .sql 文件整体喂给 mysql.exe 的 stdin（等价于 Unix 的 `mysql ... family_home < file`）。
    # 不经 shell 重定向，避免安装路径含空格/中文时的引号问题；逐字节写入，编码由 --default-character-set 决定。
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Runtime.mysql 'bin\mysql.exe'
    $psi.Arguments = Join-Args @("--defaults-extra-file=$ClientFile", '--default-character-set=utf8mb4', 'family_home')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        try {
            $bytes = [IO.File]::ReadAllBytes($File)
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $p.StandardInput.BaseStream.Flush()
        } finally { try { $p.StandardInput.Close() } catch { } }
        if (!$p.WaitForExit(300000)) { $p.Kill(); [void]$p.WaitForExit(5000); throw 'schema 快照载入超时（>300s）。' }
        $errorText = '未能及时读取 MySQL 错误输出。'
        if ($stderr.Wait(5000)) { $errorText = Protect-Text ($stderr.GetAwaiter().GetResult()) }
        if ($p.ExitCode -ne 0) { throw "schema 快照载入失败，退出码 $($p.ExitCode)：$errorText" }
    } finally { $p.Dispose() }
}
function Load-SchemaSnapshotIfEmpty {
    # 新库冷启动：family_home 零表时先 load 构建期快照（结构+种子+真 Flyway history），再起后端。
    # 为什么需要：空库若直接让后端 Flyway 按版本号严格重放，会炸在 V103（file 域 V1xx 却引用 album/recipe 表）。
    # 快照里已含完整 flyway_schema_history，后端起来即「validated 59 / up to date / no migration necessary」。
    # 已有库（升级路径）零表判定不成立 → 跳过，Flyway 增量迁移，行为不变、绝不覆盖既有数据。
    $tblCount = Sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='family_home';"
    if ($tblCount -ne '0') {
        Info "数据库已有 $tblCount 张表；跳过快照载入（改由 Flyway 增量迁移）。"
        return
    }
    $snap = Join-Path $AppDir $AppSnapshotName
    if (!(Test-Path -LiteralPath $snap -PathType Leaf)) {
        throw "family_home 为空但缺少 schema 快照（$snap）；无法安全初始化新库。请用完整产物重新运行 01-deploy.cmd。"
    }
    Set-Step '空库冷启动：载入原始 schema 快照（含真 Flyway 历史）' @((Join-Path $Logs 'mysql-error.log'))
    Info 'Loading pristine schema snapshot into empty family_home ...'
    Import-SqlFile $snap
    $hist = Sql 'SELECT COUNT(*) FROM family_home.flyway_schema_history WHERE success=1;'
    if (([int]$hist) -le 0) { throw '快照载入后 flyway_schema_history 为空；快照可能损坏，拒绝继续。' }
    Save-Text (Join-Path $State 'schema-snapshot-loaded') '1'
    Info "Snapshot loaded ($hist migrations recorded). Backend Flyway will validate and no-op."
}
function Ensure-Database {
    Set-Step '初始化并启动 MySQL 数据库' @((Join-Path $Logs 'mysql-error.log'), (Join-Path $Logs 'mysql.err.log'))
    Write-MysqlConfig
    $p = Owned-Process 'mysql'
    if (!$p) {
        Assert-PortFree $DbPort
        $mysqld = Join-Path $Runtime.mysql 'bin\mysqld.exe'
        if (!(Test-Path -LiteralPath (Join-Path $MysqlData 'mysql'))) {
            if ((Test-Path -LiteralPath (Join-Path $State 'mysql-initialized')) -or (Test-Path -LiteralPath (Join-Path $State 'mysql-secured')) -or (Test-Path -LiteralPath (Join-Path $State 'schema-stage-one'))) {
                throw 'Existing MySQL data is missing. Restore data and state together; refusing to initialize an empty replacement.'
            }
            if (@(Get-ChildItem -LiteralPath $MysqlData -Force).Count -gt 0) {
                throw 'MySQL data directory is partially initialized. Do not delete data blindly; inspect logs/mysql-error.log first.'
            }
            Info 'Initializing a private MySQL database ...'
            Invoke-Native $mysqld @("--defaults-file=$IniFile", '--initialize-insecure')
        }
        Save-Text (Join-Path $State 'mysql-initialized') '1'
        $mysqlArgs = @("--defaults-file=$IniFile")
        if (!(Test-Path -LiteralPath (Join-Path $State 'mysql-secured'))) {
            # init-file runs BEFORE accepting client connections; no password on command line.
            Save-Text $InitFile @"
ALTER USER 'root'@'localhost' IDENTIFIED BY '$($Secrets.DbRoot)';
CREATE DATABASE IF NOT EXISTS family_home CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS 'myhome'@'localhost' IDENTIFIED BY '$($Secrets.DbApp)';
GRANT ALL PRIVILEGES ON family_home.* TO 'myhome'@'localhost';
"@
            $mysqlArgs += "--init-file=$InitFile"
        }
        $p = Start-Owned 'mysql' $mysqld $mysqlArgs
    }
    $ready = $false
    $lastReason = 'SELECT 1 尚未返回预期结果。'
    for ($i = 0; $i -lt 90; $i++) {
        $p.Refresh()
        if ($p.HasExited) { throw "MySQL 进程已退出，退出码 $($p.ExitCode)。最后连接结果：$lastReason" }
        try { if ((Sql 'SELECT 1;') -eq '1') { $ready = $true; break } } catch { $lastReason = Error-Reason $_ }
        Start-Sleep -Seconds 2
    }
    if (!$ready) { throw "MySQL 启动检查超时。最后连接结果：$lastReason" }
    if ((Sql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='family_home';") -ne '1') {
        throw 'The managed database is missing; restore it instead of silently reinitializing.'
    }
    Load-SchemaSnapshotIfEmpty
    Save-Text (Join-Path $State 'mysql-secured') '1'
    if (Test-Path -LiteralPath $InitFile) { Remove-Item -LiteralPath $InitFile -Force }
}
function Stop-Database {
    Set-Step '安全停止 MySQL 数据库' @((Join-Path $Logs 'mysql-error.log'), (Join-Path $Logs 'mysql.err.log'))
    $hadRecord = Test-Path -LiteralPath (Join-Path $State 'mysql.pid.json')
    $p = Owned-Process 'mysql'
    if (!$p) {
        # A recorded process has exited: its bootstrap file can no longer be in use.
        if ($hadRecord -and (Test-Path -LiteralPath $InitFile)) { Remove-Item -LiteralPath $InitFile -Force }
        return
    }
    Write-MysqlConfig
    Info 'Shutting down MySQL safely ...'
    Invoke-Native (Join-Path $Runtime.mysql 'bin\mysqladmin.exe') @("--defaults-extra-file=$ClientFile", '--connect-timeout=10', 'shutdown')
    if (!$p.WaitForExit(120000)) { throw 'MySQL shutdown is still in progress. Do not force power off.' }
    Remove-Item -LiteralPath (Join-Path $State 'mysql.pid.json') -Force
    if (Test-Path -LiteralPath $InitFile) { Remove-Item -LiteralPath $InitFile -Force }
}

# =============================================================================
# 后端启动（java -jar，单端口托管两份 dist）
# =============================================================================
function Wait-Backend($Process) {
    $lastReason = '健康接口尚未返回结果。'
    # 产物直跑无需现场编译，启动很快；进程若中途退出会立即抛错，不会空等。
    for ($i = 0; $i -lt 150; $i++) {
        $Process.Refresh()
        if ($Process.HasExited) { throw "后端进程已退出，退出码 $($Process.ExitCode)。最后健康检查：$lastReason" }
        try {
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:$BackendPort/api/b/health" -TimeoutSec 3
            if ($r.code -eq '0' -and $r.success -eq $true -and $r.data.app -eq 'family-home-server' -and $r.data.db -match '^MySQL ') { return }
            $lastReason = Protect-Text ("健康检查未通过：code={0}, success={1}, database={2}" -f $r.code, $r.success, $r.data.db)
        } catch { $lastReason = Error-Reason $_ }
        Start-Sleep -Seconds 2
    }
    throw "后端健康检查超时。最后检查结果：$lastReason"
}
function Start-Backend {
    Assert-PortFree $BackendPort
    $jar = Join-Path $AppDir $AppJarName
    if (!(Test-Path -LiteralPath $jar -PathType Leaf)) { throw "应用产物缺失（$jar）；请先运行 01-deploy.cmd。" }
    if ([string]::IsNullOrEmpty($AppSalt)) { Read-AppMeta }
    $vars = @{
        JAVA_HOME = $Runtime.jdk
        SPRING_PROFILES_ACTIVE = 'prod'; MYSQL_HOST = '127.0.0.1'; MYSQL_PORT = "$DbPort"
        MYSQL_DATABASE = 'family_home'; MYSQL_USER = 'myhome'; MYSQL_PASSWORD = $Secrets.DbApp
        FH_VAULT_PASSWORD_KEY = $Secrets.Vault; FH_TRANSPORT_CRYPTO_SALT = $AppSalt; FH_AUTH_TOKEN_SECRET = $Secrets.Auth
        FH_STORAGE_ROOT = (Join-Path $Root 'data\files')
        # 单端口托管：后端把这两个目录当静态资源发出（/admin/** 与 /**）。
        FH_WEB_ADMIN_DIR = (Join-Path $AppDir $AppAdminDirName); FH_WEB_H5_DIR = (Join-Path $AppDir $AppH5DirName)
        LOGGING_FILE_NAME = (Join-Path $Logs 'server.log'); SERVER_ADDRESS = '127.0.0.1'; SERVER_PORT = "$BackendPort"
        # 变更记录页「当前运行版本」= 本次产物构建自的两仓 commit（取自 app\version.json，产物直跑没有 git 工作副本）。
        FH_RUNNING_COMMIT_SERVER = $AppServerCommit; FH_RUNNING_COMMIT_WEB = $AppWebCommit
        # 「部署最新」入口：后端据此分离式拉起 deploy-now.cmd（内部再 start PowerShell 跑 -Action Update），
        # 并把 Update 实时写出的 deploy-status.json 读回给前端；Update 跑到终态还会把该次追加进 deploy-history.json。
        # 缺 launcher/progress-file 后端就视为「未接入一键部署」、不显示入口。
        FH_DEPLOY_LAUNCHER = (Join-Path $PSScriptRoot 'deploy-now.cmd'); FH_DEPLOY_PROGRESS_FILE = (Join-Path $Logs 'deploy-status.json')
        FH_DEPLOY_HISTORY_FILE = (Join-Path $Logs 'deploy-history.json'); FH_DEPLOY_RELEASE_REPO = $UpdateRepo
        FH_INSTALL_DIR = $Root; FH_MYSQLDUMP_PATH = (Join-Path $Runtime.mysql 'bin\mysqldump.exe')
        # Flyway 的位置/乱序/基线策略全部沿用 JAR 内 application.yml（已验证的 prod 口径），此处不再覆盖。
    }
    $previous = @{}
    try {
        # Match Unix: inherited developer datasource/config/JVM options must not reach prod.
        foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
            $key = [string]$entry.Key
            if ($key -match '^(SPRING_|FH_|MYSQL_|SERVER_|LOGGING_)|^(JAVA_TOOL_OPTIONS|JDK_JAVA_OPTIONS|_JAVA_OPTIONS|JAVA_OPTS|JAVA_HOME|MAVEN_OPTS|GIT_TERMINAL_PROMPT)$') {
                $previous[$key] = [string]$entry.Value
                [Environment]::SetEnvironmentVariable($key, $null, 'Process')
            }
        }
        foreach ($key in $vars.Keys) {
            if (!$previous.ContainsKey($key)) { $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
            [Environment]::SetEnvironmentVariable($key, $vars[$key], 'Process')
        }
        $javaExe = Join-Path $Runtime.jdk 'bin\java.exe'
        $p = Start-Owned 'backend' $javaExe @('-Dfile.encoding=UTF-8', '-jar', $jar) $AppDir
        Wait-Backend $p
    } finally {
        foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
    }
}
function Initialize-Schema {
    $backendLogs = @((Join-Path $Logs 'server.log'), (Join-Path $Logs 'backend.err.log'), (Join-Path $Logs 'backend.out.log'))
    # 产物直跑：java -jar 启动时 Flyway 从 JAR 的 classpath:db/migration 迁移。
    # 空库已由 Load-SchemaSnapshotIfEmpty 载入含真历史的快照，后端起来即 validate + no-op；已有库走增量迁移。
    Set-Step '启动后端并从产物执行数据库迁移（Flyway）' $backendLogs
    Start-Backend
    if ((Sql "SELECT COUNT(*) FROM family_home.flyway_schema_history WHERE version='103' AND success=1;") -ne '1') {
        throw '迁移 V103 未成功应用；部署未完成。请查看 logs\server.log。'
    }
}
function Assert-ArtifactInstall([switch]$RequireInstalled) {
    $record = Join-Path $State 'installed.json'
    if (Test-Path -LiteralPath $record) {
        $installed = Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($installed.PSObject.Properties.Name -notcontains 'formatVersion' -or $installed.formatVersion -ne 4 -or $installed.runMode -cne 'artifact') {
            throw '现有安装不是本「一键部署包（产物直跑）」安装的（可能是旧版源码/离线包）；拒绝接管，请保留 data/ 和 state/。'
        }
        return
    }
    if ($RequireInstalled) { throw '尚未部署应用产物，请先运行 01-deploy.cmd。' }
}

try {
    [Console]::OutputEncoding = $Utf8
    $OutputEncoding = $Utf8
    $Root = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    $State = Join-Path $Root 'state'
    $Tools = Join-Path $Root 'tools'
    $Logs = Join-Path $Root 'logs'
    $MysqlData = Join-Path $Root 'data\mysql'
    $AppDir = Join-Path $Root 'app'
    $AppNew = Join-Path $Root 'app.new'
    $AppOld = Join-Path $Root 'app.old'
    $AppVersionFile = Join-Path $AppDir 'version.json'
    $ClientFile = Join-Path $State 'mysql-client.ini'
    $InitFile = Join-Path $State 'mysql-init.sql'
    $IniFile = Join-Path $State 'my.ini'
    Set-Step '检查系统和安装目录'
    if ($env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitOperatingSystem -or ![Environment]::Is64BitProcess) {
        throw 'Requires 64-bit Windows 10/11 and 64-bit Windows PowerShell 5.1 (included with Windows).'
    }
    if ([Environment]::OSVersion.Version.Major -lt 10 -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'This package supports Windows 10/11 Intel/AMD x64 only, not ARM or Windows 7.' }
    if ($Root -match '[%&!"\r\n]' -or $Root.StartsWith('\\') -or $Root.Length -gt 100) { throw 'Choose a local install path under 100 characters, without %, &, ! or quotes. Spaces and Chinese are supported.' }
    if ($Action -ne 'Deploy' -and !(Test-Path -LiteralPath (Join-Path $State 'runtime.json'))) { throw 'No installation found. Run 01-deploy.cmd first under the same Windows account.' }
    if ($Action -eq 'Deploy' -and (Test-Path -LiteralPath $Root) -and !(Test-Path -LiteralPath (Join-Path $State 'owner.json')) -and @(Get-ChildItem -LiteralPath $Root -Force).Count -gt 0) { throw 'Install directory is not empty and is not owned by this installer. Choose an empty directory.' }
    foreach ($dir in @($Root, $State, $Tools, $Logs, $MysqlData, (Join-Path $Root 'data\files'))) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Root))
    if ($drive.DriveFormat -ne 'NTFS') { throw 'Install on an NTFS disk (MyHome file deduplication requires hard links).' }
    if ($Action -eq 'Deploy' -and $drive.AvailableFreeSpace -lt 4294967296) { throw 'At least 4 GB free disk space is required for first deployment.' }
    Set-Step '检查安装目录权限和操作锁'
    Secure-State
    try { $Lock = [IO.File]::Open((Join-Path $State 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw "无法获取操作锁（可能有部署/启停操作正在运行，或目录不可写）：$(Error-Reason $_)" }
    $owner = Join-Path $State 'owner.json'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (Test-Path -LiteralPath $owner) {
        $saved = Get-Content -LiteralPath $owner -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.sid -ne $sid -or $saved.root -ne $Root) { throw 'Use the original Windows user and install path; this install must not be moved.' }
    } else { Save-Json $owner @{ sid = $sid; root = $Root; kind = 'MyHome-Windows' } }
    Set-Step '创建本次操作日志'
    $logPath = Join-Path $Logs "$Action.log"
    if (Test-Path -LiteralPath $logPath) { Move-Item -LiteralPath $logPath -Destination "$logPath.$([DateTime]::Now.ToString('yyyyMMddHHmmssfff'))" }
    Save-Text $logPath ''
    $RunLog = $logPath
    Info "Action: $Action | Data/install directory: $Root | $([DateTime]::Now.ToString('s'))"
    # 读取 app/update 段（jar 名、dist 目录名、Release 仓库等），供各 action 使用。
    $pkgPath = Join-Path $PSScriptRoot 'packages.json'
    if (Test-Path -LiteralPath $pkgPath -PathType Leaf) {
        $Package = Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Load-AppManifest
    }
    # 只有 Update 才上报进度：Deploy/Start/Stop 由用户在窗口里直接看，不需要写 deploy-status.json。
    if ($Action -eq 'Update') { Initialize-DeployStatus }
    Set-Step '检查产物直跑安装身份（不接管旧版源码/离线安装）'
    Assert-ArtifactInstall -RequireInstalled:($Action -ne 'Deploy')
    if ($Action -eq 'Deploy' -or $Action -eq 'Update') {
        Set-Step '读取格式 4 的一键部署包清单'
        if (!$Package) { throw '缺少 packages.json；请重新完整拷贝一键部署包。' }
        if ($Package.PSObject.Properties.Name -notcontains 'runMode' -or $Package.formatVersion -ne 4 -or $Package.offline -isnot [bool] -or $Package.offline -or $Package.runMode -cne 'artifact' -or $Package.platform -cne 'windows-x64') {
            throw '仅支持 formatVersion=4、offline=false、runMode=artifact 的 Windows x64 一键部署包；请重新完整拷包。'
        }
        if ($Action -eq 'Update' -and [string]::IsNullOrEmpty($UpdateRepo)) {
            throw '清单缺少 update.repo，无法定位 GitHub Release；请重新完整拷贝一键部署包。'
        }
    }
    Set-Step '加载加密凭据'
    Load-Secrets
    if ($Action -eq 'Deploy') {
        Ensure-VcRuntime
        Set-Step '解压并校验工具链（JDK / MySQL）'
        $Runtime = @{
            jdk = (Install-Zip $Package.jdk 'jdk' 'bin\java.exe')
            mysql = (Install-Zip $Package.mysql 'mysql' 'bin\mysqld.exe')
        }
        if (!(Test-Path -LiteralPath (Join-Path $Runtime.jdk 'bin\java.exe') -PathType Leaf)) { throw "JDK 安装不完整（$($Runtime.jdk)\bin\java.exe）。" }
        if (!(Test-Path -LiteralPath (Join-Path $Runtime.mysql 'bin\mysqld.exe') -PathType Leaf)) { throw "MySQL 安装不完整（$($Runtime.mysql)\bin\mysqld.exe）。" }
        Set-Step '保存运行环境记录'
        Save-Json (Join-Path $State 'runtime.json') $Runtime
        # 解包随包携带的应用产物（先停可能在跑的后端；数据库、密钥、上传文件一律保留）。
        Stop-Owned 'backend'
        Install-App
        Write-Installed $AppVersion $AppServerCommit $AppWebCommit ([DateTime]::UtcNow.ToString('o')) ''
    } else {
        Set-Step '读取已有运行环境记录'
        $Runtime = Get-Content -LiteralPath (Join-Path $State 'runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($need in @('jdk', 'mysql')) {
            if (!$Runtime.$need) { throw "运行环境记录缺少 $need；请用同一一键部署包重新运行 01-deploy.cmd。" }
        }
        if (!(Test-Path -LiteralPath (Join-Path $AppDir $AppJarName) -PathType Leaf) -or !(Test-Path -LiteralPath $AppVersionFile -PathType Leaf)) {
            throw "已部署的应用产物不完整（$AppDir）；请运行 01-deploy.cmd 重新解包，不要删除 data/ 或 state/。"
        }
        Read-AppMeta
        if ($Action -eq 'Update') {
            # 先停后端再下载-校验-替换（jar 文件被运行中的 JVM 占用；替换后由主流程尾部重启）。
            Stop-Owned 'backend'
            if (Run-Update) { Info "已替换到新版本：$AppVersion" } else { Info "已是最新版本：$AppVersion（未替换产物）" }
        } else {
            Stop-Owned 'backend'
        }
    }
    if ($Action -eq 'Stop') {
        Stop-Database
        Info 'Stopped. Data, photos and encryption keys are retained.'
    } else {
        Ensure-Database
        Initialize-Schema
        # 后端通过健康检查后才算部署完成；这条 done 由分离出来的部署进程写，重启后的新后端读同一文件接着显示。
        if ($script:DeployActive) { Add-DeployLine "部署完成：后端已重启并通过健康检查（版本 $AppVersion）"; Write-DeployStatus 'done'; $script:DeployActive = $false }
        Set-Step '整理历史日志和访问入口'
        Get-ChildItem -LiteralPath $Logs -File | Where-Object { $_.Name -match '\.log\.\d{17}$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force
        Info 'Ready. Open these addresses ON THIS laptop:'
        Write-Host "  C-end: http://localhost:$BackendPort/"
        Write-Host "  Admin: http://localhost:$BackendPort/admin/"
        Write-Host "  Running version: $AppVersion"
        Write-Host '  Fresh database: select 大宝 (administrator) or 小宝; initial password: 123456.'
        Write-Host '  Change both passwords in Admin > Personal profile before saving real data.'
        Write-Host '  Existing account passwords are NEVER reset by this script.'
        Write-Host "  Logs: $Logs"
        Write-Host '  Restart after Windows reboot: 02-start.cmd. Deploy latest release: 04-update.cmd. Shut down: 03-stop.cmd.'
        Write-Host '  No automatic boot task, firewall rule, LAN exposure or sleep-setting changes were made.'
        Save-Text (Join-Path $Root 'open-myhome.url') "[InternetShortcut]`r`nURL=http://localhost:$BackendPort/`r`n"
        try { Start-Process "http://localhost:$BackendPort/" }
        catch { Write-Diagnostic ("[浏览器未自动打开] {0}。服务已就绪，请在 Edge/Chrome 手动打开上述地址。" -f (Error-Reason $_)) Yellow }
    }
} catch {
    $ExitCode = 1
    # 部署失败也要落盘：前端轮询到 failed 就停下并展示原因，不会一直转圈。
    if ($script:DeployActive) {
        $deployReason = Error-Reason $_
        $script:DeployPhase = "部署失败（$script:CurrentStep）"
        Add-DeployLine "部署失败：$deployReason" 'error'
        Write-DeployStatus 'failed' $deployReason
    }
    Show-Failure $_
} finally {
    # A losing concurrent invocation MUST NOT remove the lock owner's client credentials.
    # Interrupted init-file startup retains its private file until MySQL is ready or shut down.
    if ($Lock) {
        try {
            if (Test-Path -LiteralPath $ClientFile) { Remove-Item -LiteralPath $ClientFile -Force -ErrorAction Stop }
            if ((Test-Path -LiteralPath (Join-Path $State 'mysql-secured')) -and (Test-Path -LiteralPath $InitFile)) {
                Remove-Item -LiteralPath $InitFile -Force -ErrorAction Stop
            }
        } catch {
            $ExitCode = 1
            Set-Step '清理本次操作的临时凭据文件'
            Show-Failure $_
        } finally { $Lock.Dispose() }
    }
    $Secrets.Clear()
}
exit $ExitCode
