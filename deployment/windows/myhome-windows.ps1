#requires -Version 5.1
<#
Windows 10/11 x64 一键部署包（联网 · 源码直跑）。工具链（git/JDK/Node/Maven/pnpm/MySQL/VC++）
随包携带并逐一校验 SHA256；应用源码在部署时从 GitHub 拉取，后端 mvn spring-boot:run、
前端 pnpm dev 直接跑源码，不再预编译 JAR / 静态产物。首次部署与「部署最新」都需要联网：
源码走 GitHub，后端依赖走 Maven Central，前端依赖走 npm registry。通过 .cmd 启动器运行。
不修改任何机器级安全设置（执行策略/防火墙），dev 服务只绑定 127.0.0.1。
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
$Logs = $null
$DbPort = 13306
$BackendPort = 8080
$AdminPort = 5173
$H5Port = 5174
$Lock = $null
$Secrets = @{}
$ClientFile = $null
$InitFile = $null
$Package = $null
$Runtime = $null
$ExitCode = 0
$CurrentStep = '检查系统和安装目录'
$DiagnosticFiles = @()
$RunLog = $null
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
$DeployFromCommits = @{}
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
    $launcher = @{ Deploy = '01-deploy.cmd'; Start = '02-start.cmd'; Stop = '03-stop.cmd' }[$script:Action]
    Write-Diagnostic "修复上述原因后，重新运行 $launcher（自定义安装目录需使用相同参数）。"
}
function Save-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $script:Utf8) }
function Save-Json([string]$Path, $Value) {
    $tmp = "$Path.tmp"
    Save-Text $tmp ($Value | ConvertTo-Json -Depth 8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Get-SourceCommit([string]$Dir) {
    # 运行版本 = 这份源码当前的 git HEAD；供后端注入 FH_RUNNING_COMMIT_* 后在变更记录页显示「当前运行」。
    try {
        $gitExe = Join-Path $Runtime.git 'cmd\git.exe'
        $commit = Invoke-Capture $gitExe @('-C', $Dir, 'rev-parse', 'HEAD') $Dir
        if ($commit -match '^[0-9a-f]{40}$') { return $commit }
    } catch { }
    return ''
}
function Initialize-DeployStatus {
    # 后端点火时已写过一份带 targetCommits 的初始 deploy-status.json；这里接管它、保留目标 commit，
    # runId 沿用后端注入的 FH_DEPLOY_RUN_ID（手动 04-update.cmd 没有就现生成一个）。
    $script:DeployRunId = if ($env:FH_DEPLOY_RUN_ID) { $env:FH_DEPLOY_RUN_ID } else { [guid]::NewGuid().ToString() }
    $script:DeployStatusPath = Join-Path $Logs 'deploy-status.json'
    # 部署历史：本次跑到终态时把整条状态前插进这个数组文件，供后端 /deploy/history 只读回吐给超管。
    $script:DeployHistoryPath = Join-Path $Logs 'deploy-history.json'
    $script:DeployTargetCommits = @{}
    if (Test-Path -LiteralPath $script:DeployStatusPath) {
        try {
            $existing = Get-Content -LiteralPath $script:DeployStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing -and $existing.targetCommits) { $script:DeployTargetCommits = $existing.targetCommits }
        } catch { }
    }
    $script:DeployStartedAt = [DateTime]::UtcNow.ToString('o')
    $script:DeployPhase = '开始部署最新代码'
    $script:DeployLines = New-Object 'System.Collections.Generic.List[object]'
    # fromCommits（本次部署前两仓的 HEAD）在 Update 拉取源码前才抓——那时 Runtime.git 才就绪，见主流程。
    $script:DeployFromCommits = @{}
    $script:DeployResultCommits = @{}
    $script:DeployActive = $true
    Add-DeployLine '部署脚本已启动：git pull 两仓 + 重启前后端'
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
    Set-Step "校验本地工具链文件 $relative"
    if (!(Check-Hash $file $Spec.hash $Spec.algorithm)) {
        throw "本地工具链文件缺失或 SHA256 不符：$relative。请重新完整拷贝一键部署包（包含 runtime/）；工具链不联网下载。"
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
    # MinGit 等归档把内容平铺在根（directory 为空），此时 staging 本身即顶层。
    $top = if ([string]::IsNullOrEmpty($Spec.directory)) { $staging } else { Get-SafePath $staging $Spec.directory }
    if (!(Test-Path -LiteralPath (Join-Path $top $Probe))) { throw "Incomplete $Name archive." }
    if (Test-Path -LiteralPath $runtimeHome) { throw "Incomplete runtime directory: $runtimeHome . Keep data/state; remove only this incomplete tools directory and retry." }
    Move-Item -LiteralPath $top -Destination $runtimeHome
    Save-Text $stamp $Spec.hash
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    return $runtimeHome
}
function Install-Tarball($Spec, [string]$Name, [string]$Probe) {
    # npm tarball（pnpm）用 Windows 内置 bsdtar 解包；解出顶层目录名为 package。
    $tgz = Get-LocalPackage $Spec
    Set-Step "检查 $Name 运行环境"
    $runtimeHome = Join-Path $Tools $Name
    $stamp = Join-Path $runtimeHome '.package-hash'
    if ((Test-Path -LiteralPath $stamp) -and (Test-Path -LiteralPath (Join-Path $runtimeHome $Probe))) {
        if (([IO.File]::ReadAllText($stamp)).Trim() -ne $Spec.hash) { throw "Installed $Name differs from this package." }
        return $runtimeHome
    }
    Set-Step "解压并安装 $Name"
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (!(Test-Path -LiteralPath $tar -PathType Leaf)) { throw 'Windows 缺少内置 tar.exe（需 Windows 10 1803+），无法解压 pnpm。' }
    $staging = Join-Path $Tools ($Name + '.extract')
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Invoke-Native $tar @('-xzf', $tgz, '-C', $staging)
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
function Invoke-Capture([string]$Exe, [string[]]$Arguments, [string]$WorkingDir = $Root) {
    # 与 Invoke-Native 不同：捕获并返回 stdout（用于 git rev-parse 这类要读结果的命令）。
    if (!(Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "Executable not found: $Exe" }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = Join-Args $Arguments
    $psi.WorkingDirectory = $WorkingDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        if (!$p.WaitForExit(120000)) { $p.Kill(); throw "$([IO.Path]::GetFileName($Exe)) 等待 120 秒后超时。" }
        if ($p.ExitCode -ne 0) {
            throw ("{0} 执行失败，退出码 {1}：{2}" -f [IO.Path]::GetFileName($Exe), $p.ExitCode, (Protect-Text $stderr))
        }
        return $stdout.Trim()
    } finally { $p.Dispose() }
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
    # 源码直跑下 backend 是 mvn.cmd→fork 的 JVM、web 是 node→vite 子进程，单杀父进程会留下孤儿。
    # taskkill /T 只终止这个已校验 PID 的整棵进程树；MySQL 不走这里（用 mysqladmin 优雅关闭）。
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
    $path = Join-Path $State 'secrets.xml'
    if (!(Test-Path -LiteralPath $path)) {
        if ((Test-Path -LiteralPath (Join-Path $MysqlData 'mysql')) -or (Test-Path -LiteralPath (Join-Path $State 'installed.json'))) {
            throw 'Secrets are missing from an existing install. Restore state/secrets.xml; never regenerate the vault key over existing data.'
        }
        $initial = @{
            DbRoot = (Random-Base64 36); DbApp = (Random-Base64 36)
            Vault = (Random-Base64 32); Transport = (Random-Base64 24); Auth = (Random-Base64 48)
        }
        $encrypted = @{}
        foreach ($key in $initial.Keys) { $encrypted[$key] = ConvertTo-SecureString $initial[$key] -AsPlainText -Force }
        $encrypted | Export-Clixml -LiteralPath "$path.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$path.tmp" -Destination $path
    }
    try {
        $saved = Import-Clixml -LiteralPath $path
        foreach ($key in @('DbRoot', 'DbApp', 'Vault', 'Transport', 'Auth')) {
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
function Wait-Backend($Process) {
    $lastReason = '健康接口尚未返回结果。'
    # 源码直跑首次启动要现下 Maven 依赖并编译，耗时可达十几分钟；进程若中途退出会立即抛错，不会空等。
    for ($i = 0; $i -lt 450; $i++) {
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
    $serverDir = Join-Path $Root 'src\server'
    if (!(Test-Path -LiteralPath (Join-Path $serverDir 'pom.xml') -PathType Leaf)) { throw '后端源码缺失（src\server\pom.xml）；请先运行 01-deploy.cmd 拉取源码。' }
    $vars = @{
        JAVA_HOME = $Runtime.jdk; MAVEN_OPTS = '-Xms128m -Xmx768m -Dfile.encoding=UTF-8'; GIT_TERMINAL_PROMPT = '0'
        SPRING_PROFILES_ACTIVE = 'prod'; MYSQL_HOST = '127.0.0.1'; MYSQL_PORT = "$DbPort"
        MYSQL_DATABASE = 'family_home'; MYSQL_USER = 'myhome'; MYSQL_PASSWORD = $Secrets.DbApp
        FH_VAULT_PASSWORD_KEY = $Secrets.Vault; FH_TRANSPORT_CRYPTO_SALT = $Secrets.Transport
        FH_AUTH_TOKEN_SECRET = $Secrets.Auth; FH_STORAGE_ROOT = (Join-Path $Root 'data\files')
        LOGGING_FILE_NAME = (Join-Path $Logs 'server.log'); SERVER_ADDRESS = '127.0.0.1'; SERVER_PORT = "$BackendPort"
        SPRING_FLYWAY_BASELINE_ON_MIGRATE = 'false'; SPRING_FLYWAY_OUT_OF_ORDER = 'true'
        SPRING_FLYWAY_LOCATIONS = 'classpath:db/migration'
        # 变更记录页「当前运行版本」= 各自源码目录的 git HEAD（源码直跑没有烘焙快照，靠这两个环境变量给真值）。
        FH_RUNNING_COMMIT_SERVER = (Get-SourceCommit $serverDir); FH_RUNNING_COMMIT_WEB = (Get-SourceCommit (Join-Path $Root 'src\web'))
        # 「部署最新」入口：后端据此分离式拉起 deploy-now.cmd（内部再 start PowerShell 跑 -Action Update），
        # 并把 Update 实时写出的 deploy-status.json 读回给前端；Update 跑到终态还会把该次追加进 deploy-history.json，
        # 后端 /deploy/history 只读它给超管看部署历史。缺 launcher/progress-file 后端就视为「未接入一键部署」、不显示入口。
        FH_DEPLOY_LAUNCHER = (Join-Path $PSScriptRoot 'deploy-now.cmd'); FH_DEPLOY_PROGRESS_FILE = (Join-Path $Logs 'deploy-status.json')
        FH_DEPLOY_HISTORY_FILE = (Join-Path $Logs 'deploy-history.json')
        FH_INSTALL_DIR = $Root
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
        # 从聚合根 pom 选中 fh-boot 模块跑 spring-boot:run；-am 先构建其依赖模块（fh-common 等）。
        $mvn = Join-Path $Runtime.maven 'bin\mvn.cmd'
        $p = Start-Owned 'backend' $mvn @('-B', '-f', (Join-Path $serverDir 'pom.xml'), '-pl', 'fh-boot', '-am', 'spring-boot:run') $serverDir
        Wait-Backend $p
    } finally {
        foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
    }
}
function Initialize-Schema {
    $backendLogs = @((Join-Path $Logs 'server.log'), (Join-Path $Logs 'backend.err.log'), (Join-Path $Logs 'backend.out.log'))
    # 源码直跑：spring-boot:run 启动时 Flyway 直接从 src/server 的 classpath:db/migration 迁移，
    # 空库按版本号顺序应用（out-of-order=true 兜住历史 V103 次序），不再需要离线那套 bootstrap 两阶段。
    Set-Step '启动后端并从源码执行数据库迁移（Flyway）' $backendLogs
    Start-Backend
    if ((Sql "SELECT COUNT(*) FROM family_home.flyway_schema_history WHERE version='103' AND success=1;") -ne '1') {
        throw '迁移 V103 未成功应用；部署未完成。请查看 logs\server.log。'
    }
}
function Assert-SourceInstall([switch]$RequireInstalled) {
    $record = Join-Path $State 'installed.json'
    if (Test-Path -LiteralPath $record) {
        $installed = Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($installed.PSObject.Properties.Name -notcontains 'formatVersion' -or $installed.formatVersion -ne 3 -or $installed.runMode -cne 'source') {
            throw '现有安装不是本「一键部署包（源码直跑）」安装的（可能是旧版离线包）；拒绝接管，请保留 data/ 和 state/。'
        }
        return
    }
    # 没有安装身份时，绝不在已有旧离线产物或他人目录上就地部署。
    if (Test-Path -LiteralPath (Join-Path $Root 'app')) { throw '检测到旧版离线安装的 app 目录，拒绝接管；请保留 data/ 和 state/。' }
    if ($RequireInstalled) { throw '尚未部署源码，请先运行 01-deploy.cmd。' }
}
function Assert-TransportSalt {
    try {
        $bytes = [Convert]::FromBase64String($Secrets.Transport)
        if ($bytes.Length -ne 24 -or [Convert]::ToBase64String($bytes) -cne $Secrets.Transport) { throw 'Invalid transport salt.' }
    } catch { throw '持久化 Transport 盐必须是 24 字节的标准 Base64；请恢复原 state/secrets.xml，不能重新生成密钥或使用开发盐。' }
}
function Fetch-Source {
    # 联网从 GitHub 拉取：源码目录不存在则 clone，已存在则 fetch+reset 到最新（幂等，可重复运行）。
    # 两仓都是 public，https 无需 token。src/ 是安装器自己管理的克隆，不做人工改动，故 reset --hard 安全。
    Assert-TransportSalt
    $gitExe = Join-Path $Runtime.git 'cmd\git.exe'
    if (!(Test-Path -LiteralPath $gitExe -PathType Leaf)) { throw "便携 git 缺失：$gitExe。请重新完整拷贝一键部署包（含 runtime/）。" }
    $previous = @{}
    try {
        # 让 git 遇到需要交互输入凭据时直接失败，而不是挂起等待。
        foreach ($key in @('GIT_TERMINAL_PROMPT', 'GIT_ASKPASS')) {
            $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        }
        [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_ASKPASS', '', 'Process')
        $repos = @{}
        foreach ($key in @('server', 'web')) {
            $spec = $Package.repos.$key
            if (!$spec -or $spec.url -notmatch '^https://github\.com/[^/]+/[^/]+\.git$' -or [string]$spec.directory -notmatch '^[A-Za-z0-9._/-]+$' -or [string]$spec.branch -notmatch '^[A-Za-z0-9._/-]+$') {
                throw "清单 repos.$key 不合法（url/directory/branch）；请重新完整拷贝一键部署包。"
            }
            $target = Get-SafePath $Root ($spec.directory.Replace('/', '\'))
            Set-Step "拉取源码 $key（$($spec.directory)）"
            if (Test-Path -LiteralPath (Join-Path $target '.git')) {
                Invoke-Native $gitExe @('-C', $target, 'fetch', '--quiet', '--prune', 'origin', $spec.branch)
                Invoke-Native $gitExe @('-C', $target, 'checkout', '--quiet', $spec.branch)
                Invoke-Native $gitExe @('-C', $target, 'reset', '--hard', '--quiet', "origin/$($spec.branch)")
            } else {
                if (Test-Path -LiteralPath $target) { throw "源码目录已存在但不是 git 仓库：$target。请清空后重试。" }
                $parent = [IO.Path]::GetDirectoryName($target)
                if (!(Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Invoke-Native $gitExe @('clone', '--quiet', '--branch', $spec.branch, '--single-branch', $spec.url, $target)
            }
            $commit = Invoke-Capture $gitExe @('-C', $target, 'rev-parse', 'HEAD') $target
            if ($commit -notmatch '^[0-9a-f]{40}$') { throw "无法读取 $key 的提交号：$commit" }
            $repos[$key] = @{ commit = $commit; directory = $spec.directory; branch = $spec.branch; url = $spec.url }
        }
        if (!(Test-Path -LiteralPath (Join-Path $Root 'src\server\pom.xml') -PathType Leaf)) { throw '后端源码缺少 src\server\pom.xml；拉取的仓库结构不符。' }
        if (!(Test-Path -LiteralPath (Join-Path $Root 'src\web\package.json') -PathType Leaf)) { throw '前端源码缺少 src\web\package.json；拉取的仓库结构不符。' }
        return $repos
    } finally {
        foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
    }
}
function Install-App {
    Assert-SourceInstall
    $repos = Fetch-Source
    # 源码就位后才停旧服务；数据库、密钥、上传文件一律保留，迁移交给后端启动时的 Flyway。
    Stop-Owned 'web-admin'
    Stop-Owned 'web-h5'
    Stop-Owned 'backend'
    $record = @{
        formatVersion = 3; offline = $false; runMode = 'source'
        repos = $repos; installedAt = [DateTime]::UtcNow.ToString('o')
    }
    Set-Step '记录本次部署的源码版本'
    Save-Json (Join-Path $State 'installed.json') $record
}
function Start-Frontend {
    Assert-PortFree $AdminPort
    Assert-PortFree $H5Port
    $webDir = Join-Path $Root 'src\web'
    if (!(Test-Path -LiteralPath (Join-Path $webDir 'package.json') -PathType Leaf)) { throw '前端源码缺失（src\web\package.json）；请先运行 01-deploy.cmd 拉取源码。' }
    $nodeExe = Join-Path $Runtime.node 'node.exe'
    $pnpmCjs = Join-Path $Runtime.pnpm 'bin\pnpm.cjs'
    if (!(Test-Path -LiteralPath $pnpmCjs -PathType Leaf)) { throw "便携 pnpm 缺失：$pnpmCjs。请重新完整拷贝一键部署包（含 runtime/）。" }
    $vars = @{
        # 传输盐必须与后端一致，否则登录解密失败；两端 dev server 都读这个 VITE_ 变量。
        VITE_FH_TRANSPORT_CRYPTO_SALT = $Secrets.Transport
        # 让 pnpm/vite 用便携 node，而不是系统 PATH 里可能存在的其它版本。
        PATH = ((Join-Path $Runtime.node '') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'Process'))
    }
    $previous = @{}
    try {
        foreach ($key in $vars.Keys) {
            $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, $vars[$key], 'Process')
        }
        Set-Step '安装前端依赖（pnpm install）' @((Join-Path $Logs 'web-admin.err.log'), (Join-Path $Logs 'web-h5.err.log'))
        Invoke-Native $nodeExe @($pnpmCjs, 'install', '--frozen-lockfile')
        Set-Step '启动前端 dev server（admin:5173 / h5:5174）'
        [void](Start-Owned 'web-admin' $nodeExe @($pnpmCjs, '--filter', '@family-home/admin', 'dev', '--', '--host', '127.0.0.1', '--strictPort') $webDir)
        [void](Start-Owned 'web-h5' $nodeExe @($pnpmCjs, '--filter', '@family-home/h5', 'dev', '--', '--host', '127.0.0.1', '--strictPort') $webDir)
    } finally {
        foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
    }
    foreach ($check in @(@{ port = $AdminPort; path = '/admin/' }, @{ port = $H5Port; path = '/' })) {
        $ready = $false
        $lastReason = '尚未收到 HTTP 响应。'
        for ($i = 0; $i -lt 60; $i++) {
            try {
                $r = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$($check.port)$($check.path)" -TimeoutSec 3
                if ($r.StatusCode -eq 200) { $ready = $true; break }
                $lastReason = "HTTP 状态码 $($r.StatusCode)"
            } catch { $lastReason = Error-Reason $_ }
            Start-Sleep -Seconds 1
        }
        if (!$ready) { throw "前端访问检查失败：http://127.0.0.1:$($check.port)$($check.path)。最后检查结果：$lastReason" }
    }
}

try {
    [Console]::OutputEncoding = $Utf8
    $OutputEncoding = $Utf8
    $Root = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    $State = Join-Path $Root 'state'
    $Tools = Join-Path $Root 'tools'
    $Logs = Join-Path $Root 'logs'
    $MysqlData = Join-Path $Root 'data\mysql'
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
    if ($Action -eq 'Deploy' -and $drive.AvailableFreeSpace -lt 8589934592) { throw 'At least 8 GB free disk space is required for first deployment.' }
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
    # 只有 Update 才上报进度：Deploy/Start/Stop 由用户在窗口里直接看，不需要写 deploy-status.json。
    if ($Action -eq 'Update') { Initialize-DeployStatus }
    Set-Step '检查源码直跑安装身份（不接管旧版离线安装）'
    Assert-SourceInstall -RequireInstalled:($Action -ne 'Deploy')
    if ($Action -eq 'Deploy' -or $Action -eq 'Update') {
        Set-Step '读取格式 3 的一键部署包清单'
        $Package = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'packages.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Package.PSObject.Properties.Name -notcontains 'runMode' -or $Package.formatVersion -ne 3 -or $Package.offline -isnot [bool] -or $Package.offline -or $Package.runMode -cne 'source' -or $Package.platform -cne 'windows-x64') {
            throw '仅支持 formatVersion=3、offline=false、runMode=source 的 Windows x64 一键部署包；请重新完整拷包。'
        }
        foreach ($key in @('server', 'web')) {
            if (!$Package.repos.$key) { throw "清单缺少 repos.$key；请重新完整拷贝一键部署包。" }
        }
    }
    Set-Step '加载加密凭据'
    Load-Secrets
    Assert-TransportSalt
    if ($Action -eq 'Deploy') {
        Ensure-VcRuntime
        $Runtime = @{
            git = (Install-Zip $Package.git 'git' 'cmd\git.exe')
            jdk = (Install-Zip $Package.jdk 'jdk' 'bin\java.exe')
            node = (Install-Zip $Package.node 'node' 'node.exe')
            maven = (Install-Zip $Package.maven 'maven' 'bin\mvn.cmd')
            pnpm = (Install-Tarball $Package.pnpm 'pnpm' 'bin\pnpm.cjs')
            mysql = (Install-Zip $Package.mysql 'mysql' 'bin\mysqld.exe')
        }
        Set-Step '保存运行环境记录'
        Save-Json (Join-Path $State 'runtime.json') $Runtime
        Install-App
    } else {
        Set-Step '读取已有运行环境记录'
        $Runtime = Get-Content -LiteralPath (Join-Path $State 'runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($need in @('git', 'jdk', 'node', 'maven', 'pnpm', 'mysql')) {
            if (!$Runtime.$need) { throw "运行环境记录缺少 $need；请用同一一键部署包重新运行 01-deploy.cmd。" }
        }
        if ($Action -eq 'Start' -or $Action -eq 'Update') {
            Set-Step '检查已拉取的源码'
            foreach ($relative in @('src\server\pom.xml', 'src\web\package.json')) {
                if (!(Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)) { throw '已部署的源码不完整；请运行 01-deploy.cmd 重新拉取源码，不要删除 data/ 或 state/。' }
            }
        }
        if ($Action -eq 'Update') {
            Stop-Owned 'web-admin'
            Stop-Owned 'web-h5'
            Stop-Owned 'backend'
            # 拉取前先记下两仓当前 HEAD = 本次部署的「从哪个版本」，供部署历史展示「从 X 到 Y」。
            if ($script:DeployActive) {
                $script:DeployFromCommits = @{
                    server = (Get-SourceCommit (Join-Path $Root 'src\server'))
                    web    = (Get-SourceCommit (Join-Path $Root 'src\web'))
                }
            }
            $repos = Fetch-Source
            $script:DeployResultCommits = @{ server = $repos.server.commit; web = $repos.web.commit }
            Add-DeployLine "已拉取最新源码：后端 $($repos.server.commit.Substring(0, 7))、前端 $($repos.web.commit.Substring(0, 7))"
            $installed = Get-Content -LiteralPath (Join-Path $State 'installed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $record = @{
                formatVersion = 3; offline = $false; runMode = 'source'
                repos = $repos; installedAt = $installed.installedAt; updatedAt = [DateTime]::UtcNow.ToString('o')
            }
            Set-Step '记录本次更新的源码版本'
            Save-Json (Join-Path $State 'installed.json') $record
        } else {
            Stop-Owned 'web-admin'
            Stop-Owned 'web-h5'
            Stop-Owned 'backend'
        }
    }
    if ($Action -eq 'Stop') {
        Stop-Database
        Info 'Stopped. Data, photos and encryption keys are retained.'
    } else {
        Ensure-Database
        Initialize-Schema
        Start-Frontend
        # 前后端都通过健康检查后才算部署完成；这条 done 由分离出来的部署进程写，重启后的新后端读同一文件接着显示。
        if ($script:DeployActive) { Add-DeployLine '部署完成：前后端已重启并通过健康检查'; Write-DeployStatus 'done' }
        Set-Step '整理历史日志和访问入口'
        Get-ChildItem -LiteralPath $Logs -File | Where-Object { $_.Name -match '\.log\.\d{17}$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force
        Info 'Ready. Open these addresses ON THIS laptop:'
        Write-Host "  C-end: http://localhost:$H5Port/"
        Write-Host "  Admin: http://localhost:$AdminPort/admin/"
        Write-Host '  Fresh database: select 大宝 (administrator) or 小宝; initial password: 123456.'
        Write-Host '  Change both passwords in Admin > Personal profile before saving real data.'
        Write-Host '  Existing account passwords are NEVER reset by this script.'
        Write-Host "  Logs: $Logs"
        Write-Host '  Restart after Windows reboot: 02-start.cmd. Deploy latest source: 04-update.cmd. Shut down: 03-stop.cmd.'
        Write-Host '  No automatic boot task, firewall rule, LAN exposure or sleep-setting changes were made.'
        Save-Text (Join-Path $Root 'open-myhome.url') "[InternetShortcut]`r`nURL=http://localhost:$H5Port/`r`n"
        try { Start-Process "http://localhost:$H5Port/" }
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
