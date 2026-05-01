[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# =======================
# UWF-Manager.ps1
# 说明：用于在 Windows 上安全管理 UWF（统一写入筛选器）
# 兼容：Windows PowerShell 5.1
# =======================

$Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:LogPath = Join-Path $Script:ScriptDir 'UWF-Manager.log'
$Script:PendingReboot = $false

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Relaunch-AsAdmin {
    Write-Host "检测到当前不是管理员权限，正在尝试以管理员身份重新启动脚本..." -ForegroundColor Yellow
    Write-Log "当前非管理员，尝试提权重启脚本"

    $psExe = Join-Path $PSHOME 'powershell.exe'
    $arg = "-ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""

    try {
        Start-Process -FilePath $psExe -ArgumentList $arg -Verb RunAs | Out-Null
        exit
    }
    catch {
        Write-Host "无法自动提权，请右键使用“以管理员身份运行”打开。" -ForegroundColor Red
        Write-Log "提权失败：$($_.Exception.Message)"
        exit 1
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$time] $Message"
    Add-Content -Path $Script:LogPath -Value $line -Encoding UTF8
}

function Run-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [switch]$IgnoreError
    )

    Write-Host "`n正在执行：$Command" -ForegroundColor Cyan
    Write-Log "执行命令：$Command"

    $output = ""
    try {
        $output = cmd.exe /c $Command 2>&1 | Out-String
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            Write-Host $output.TrimEnd()
        }
        Write-Log "命令输出：`n$output"
    }
    catch {
        $msg = $_.Exception.Message
        Write-Host "命令执行异常：$msg" -ForegroundColor Red
        Write-Log "命令执行异常：$msg"
        if (-not $IgnoreError) {
            return $null
        }
    }

    return $output
}

function Confirm-Yes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [string]$Keyword
    )

    $inputText = (Read-Host "$Prompt（输入 $Keyword 继续）").Trim()
    if ($inputText -ceq $Keyword) {
        return $true
    }

    Write-Host "已取消操作。" -ForegroundColor Yellow
    return $false
}

function Ask-Reboot {
    $answer = (Read-Host "该操作需要重启后生效，是否立即重启？(Y/N)").Trim()
    if ($answer -match '^[Yy]$') {
        Run-Command -Command 'shutdown /r /t 0' | Out-Null
    }
}

function Pause-Return {
    Read-Host "`n按 Enter 返回主菜单" | Out-Null
}

function Show-MainMenu {
    Clear-Host
    Write-Host '================ UWF 管理器 ================'
    Write-Host ''
    Write-Host '[1] 查看简洁状态'
    Write-Host '[2] 查看完整状态'
    Write-Host '[3] 启用推荐配置：保护 C: + RAM Overlay 16GB'
    Write-Host '[4] 禁用 UWF'
    Write-Host '[5] 设置 Overlay 大小'
    Write-Host '[6] 添加文件/目录排除'
    Write-Host '[7] 查看排除项'
    Write-Host '[8] 删除文件/目录排除'
    Write-Host '[9] 创建 UWF 测试项'
    Write-Host '[10] 检查 UWF 测试结果'
    Write-Host '[11] 重启电脑'
    Write-Host '[12] 完全清除 UWF 配置'
    Write-Host '[0] 退出'
    Write-Host ''
    Write-Host '============================================'
}

function Show-SimpleStatus {
    $cfg = Run-Command -Command 'uwfmgr get-config' -IgnoreError
    $overlay = Run-Command -Command 'uwfmgr overlay get-config' -IgnoreError
    $vol = Run-Command -Command 'uwfmgr volume get-config' -IgnoreError
    $fileEx = Run-Command -Command 'uwfmgr file get-exclusions all' -IgnoreError
    $regEx = Run-Command -Command 'uwfmgr registry get-exclusions' -IgnoreError

    try {
        Write-Host "`n===== 简洁状态 =====" -ForegroundColor Green

        $currentFilter = ([regex]::Match($cfg, '(?im)Current\s+Session\s*:\s*(.+)$')).Groups[1].Value.Trim()
        $nextFilter = ([regex]::Match($cfg, '(?im)Next\s+Session\s*:\s*(.+)$')).Groups[1].Value.Trim()

        $currentC = ([regex]::Match($vol, '(?ims)Volume\s+Name\s*:\s*C:.*?Current\s+Session\s*:\s*(.+?)\r?\n')).Groups[1].Value.Trim()
        $nextC = ([regex]::Match($vol, '(?ims)Volume\s+Name\s*:\s*C:.*?Next\s+Session\s*:\s*(.+?)\r?\n')).Groups[1].Value.Trim()

        $ovType = ([regex]::Match($overlay, '(?im)Type\s*:\s*(.+)$')).Groups[1].Value.Trim()
        $ovSize = ([regex]::Match($overlay, '(?im)Maximum\s+Size\s*:\s*(.+)$')).Groups[1].Value.Trim()
        $warn = ([regex]::Match($overlay, '(?im)Warning\s+Threshold\s*:\s*(.+)$')).Groups[1].Value.Trim()
        $crit = ([regex]::Match($overlay, '(?im)Critical\s+Threshold\s*:\s*(.+)$')).Groups[1].Value.Trim()

        $fileCount = ([regex]::Matches($fileEx, '(?im)^\s*[A-Za-z]:\\')).Count
        $regCount = ([regex]::Matches($regEx, '(?im)^\s*HKEY_')).Count

        if ([string]::IsNullOrWhiteSpace($currentFilter)) { $currentFilter = '未知' }
        if ([string]::IsNullOrWhiteSpace($nextFilter)) { $nextFilter = '未知' }
        if ([string]::IsNullOrWhiteSpace($currentC)) { $currentC = '未知' }
        if ([string]::IsNullOrWhiteSpace($nextC)) { $nextC = '未知' }
        if ([string]::IsNullOrWhiteSpace($ovType)) { $ovType = '未知' }
        if ([string]::IsNullOrWhiteSpace($ovSize)) { $ovSize = '未知' }
        if ([string]::IsNullOrWhiteSpace($warn)) { $warn = '未知' }
        if ([string]::IsNullOrWhiteSpace($crit)) { $crit = '未知' }

        Write-Host "当前会话筛选状态：$currentFilter"
        Write-Host "下次会话筛选状态：$nextFilter"
        Write-Host "当前 C: 是否受保护：$currentC"
        Write-Host "下次会话 C: 是否受保护：$nextC"
        Write-Host "Overlay 类型：$ovType"
        Write-Host "Overlay 最大大小：$ovSize"
        Write-Host "警告阈值：$warn"
        Write-Host "严重阈值：$crit"
        Write-Host "文件排除数量：$fileCount"
        Write-Host "注册表排除数量：$regCount"

        $needReboot = '否'
        if (($currentFilter -ne '未知' -and $nextFilter -ne '未知' -and $currentFilter -ne $nextFilter) -or
            ($currentC -ne '未知' -and $nextC -ne '未知' -and $currentC -ne $nextC) -or
            $Script:PendingReboot) {
            $needReboot = '是'
        }

        Write-Host "是否存在需要重启后生效的变更：$needReboot"
    }
    catch {
        Write-Host "解析失败，请查看完整状态。" -ForegroundColor Yellow
        Write-Log "简洁状态解析失败：$($_.Exception.Message)"
    }
}

function Show-FullStatus {
    Run-Command -Command 'uwfmgr get-config' -IgnoreError | Out-Null
    Run-Command -Command 'uwfmgr volume get-config' -IgnoreError | Out-Null
    Run-Command -Command 'uwfmgr overlay get-config' -IgnoreError | Out-Null
    Run-Command -Command 'uwfmgr file get-exclusions all' -IgnoreError | Out-Null
    Run-Command -Command 'uwfmgr registry get-exclusions' -IgnoreError | Out-Null
}

function Enable-RecommendedUWF {
    Write-Host "`n将执行以下操作："
    Write-Host '- 将关闭休眠/快速启动'
    Write-Host '- 将 Overlay 设置为 RAM 16GB'
    Write-Host '- 将保护 C:\'
    Write-Host '- 不会保护 D:\'
    Write-Host '- 需要重启生效'

    if (-not (Confirm-Yes -Prompt '确认继续吗？' -Keyword 'YES')) { return }

    Run-Command -Command 'powercfg /h off' -IgnoreError | Out-Null
    Run-Command -Command 'uwfmgr overlay set-size 16384' -IgnoreError | Out-Null
    Run-Command -Command 'uwfmgr volume protect C:\' -IgnoreError | Out-Null
    Run-Command -Command 'uwfmgr filter enable' -IgnoreError | Out-Null

    $Script:PendingReboot = $true
    Ask-Reboot
}

function Disable-UWF {
    Write-Host "`n说明："
    Write-Host '- 只是禁用 UWF 筛选器'
    Write-Host '- 保留 C: 保护配置和排除项'
    Write-Host '- 重启后生效'

    if (-not (Confirm-Yes -Prompt '确认继续吗？' -Keyword 'YES')) { return }

    Run-Command -Command 'uwfmgr filter disable' -IgnoreError | Out-Null
    $Script:PendingReboot = $true
    Ask-Reboot
}

function Set-OverlaySize {
    Write-Host "`n请选择 Overlay 大小："
    Write-Host '[1] 8192 MB'
    Write-Host '[2] 16384 MB'
    Write-Host '[3] 32768 MB'
    Write-Host '[4] 自定义 MB'
    Write-Host '[0] 返回'

    $choice = (Read-Host '请输入选项').Trim()
    $size = $null

    switch ($choice) {
        '1' { $size = 8192 }
        '2' { $size = 16384 }
        '3' { $size = 32768 }
        '4' {
            $inputMb = (Read-Host '请输入自定义 MB（正整数）').Trim()
            $tmp = 0
            if (-not [int]::TryParse($inputMb, [ref]$tmp) -or $tmp -le 0) {
                Write-Host '输入无效，必须是正整数。' -ForegroundColor Yellow
                return
            }
            $size = $tmp
        }
        '0' { return }
        default {
            Write-Host '无效选项。' -ForegroundColor Yellow
            return
        }
    }

    if ($size -lt 1024) {
        Write-Host '警告：小于 1024MB 通常不建议。' -ForegroundColor Yellow
    }

    if ($size -gt 65536) {
        if (-not (Confirm-Yes -Prompt '该值较大，确认继续吗？' -Keyword 'YES')) { return }
    }

    Run-Command -Command "uwfmgr overlay set-size $size" -IgnoreError | Out-Null
    $Script:PendingReboot = $true
    Write-Host '设置完成，需要重启后生效。' -ForegroundColor Green
    Ask-Reboot
}

function Add-FileExclusion {
    $path = (Read-Host '请输入要排除的完整路径').Trim()
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host '路径不能为空。' -ForegroundColor Yellow
        return
    }

    $normalized = $path.TrimEnd('\\')
    $dangerRoots = @(
        'C:',
        'C:\Windows',
        'C:\Users',
        'C:\Users\Brz',
        'C:\ProgramData',
        'C:\Program Files',
        'C:\Program Files (x86)'
    )

    foreach ($root in $dangerRoots) {
        $r = $root.TrimEnd('\\')
        if ($normalized -ieq $r) {
            Write-Host "拒绝：不允许直接排除高风险大目录：$root" -ForegroundColor Red
            return
        }
    }

    foreach ($root in $dangerRoots) {
        $r = $root.TrimEnd('\\')
        if ($normalized.Length -lt ($r.Length + 3) -and $normalized -like "$r*") {
            Write-Host "警告：路径过于接近高风险大目录：$root，已拒绝。" -ForegroundColor Red
            return
        }
    }

    if (-not (Test-Path -LiteralPath $path)) {
        $ans = (Read-Host '路径不存在，是否仍要添加？(Y/N)').Trim()
        if ($ans -notmatch '^[Yy]$') {
            Write-Host '已取消。' -ForegroundColor Yellow
            return
        }
    }

    Run-Command -Command "uwfmgr file add-exclusion `"$path`"" -IgnoreError | Out-Null
    $Script:PendingReboot = $true
    Write-Host '添加完成，需要重启后生效。' -ForegroundColor Green
    Ask-Reboot
}

function Show-Exclusions {
    Run-Command -Command 'uwfmgr file get-exclusions all' -IgnoreError | Out-Null
    Run-Command -Command 'uwfmgr registry get-exclusions' -IgnoreError | Out-Null
}

function Remove-FileExclusion {
    Run-Command -Command 'uwfmgr file get-exclusions all' -IgnoreError | Out-Null

    $path = (Read-Host '请输入要删除的完整路径').Trim()
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host '路径不能为空。' -ForegroundColor Yellow
        return
    }

    if (-not (Confirm-Yes -Prompt '确认删除该排除项吗？' -Keyword 'YES')) { return }

    Run-Command -Command "uwfmgr file remove-exclusion `"$path`"" -IgnoreError | Out-Null
    $Script:PendingReboot = $true
    Write-Host '删除完成，需要重启后生效。' -ForegroundColor Green
    Ask-Reboot
}

function Create-UWFTestItems {
    Run-Command -Command 'powershell -NoProfile -Command "\"uwf test\" | Out-File \"$env:USERPROFILE\Desktop\uwf-test.txt\" -Encoding UTF8"' -IgnoreError | Out-Null
    Run-Command -Command 'powershell -NoProfile -Command "New-Item -ItemType Directory -Path \"C:\uwf-test-folder\" -Force"' -IgnoreError | Out-Null
    Run-Command -Command 'reg add "HKCU\Software\UWFTest" /v TestValue /t REG_SZ /d "hello" /f' -IgnoreError | Out-Null

    Write-Host '测试项已创建。请重启后再次运行脚本并选择 [10] 检查测试结果。' -ForegroundColor Green
}

function Check-UWFTestItems {
    $fileExists = Test-Path "$env:USERPROFILE\Desktop\uwf-test.txt"
    $dirExists = Test-Path 'C:\uwf-test-folder'

    cmd.exe /c 'reg query "HKCU\Software\UWFTest" >nul 2>&1'
    $regExists = ($LASTEXITCODE -eq 0)

    if (-not $fileExists -and -not $dirExists -and -not $regExists) {
        Write-Host 'UWF 工作正常：测试文件、目录、注册表项均已在重启后消失。' -ForegroundColor Green
    }
    else {
        Write-Host 'UWF 可能未正确保护当前会话，以下项目仍存在：' -ForegroundColor Yellow
        if ($fileExists) { Write-Host '- 文件：桌面 uwf-test.txt' }
        if ($dirExists) { Write-Host '- 目录：C:\uwf-test-folder' }
        if ($regExists) { Write-Host '- 注册表：HKCU\Software\UWFTest' }
    }

    Write-Log "检查测试结果：file=$fileExists; dir=$dirExists; reg=$regExists"
}

function Clear-UWFConfig {
    Write-Host "`n这是高级危险操作。将执行："
    Write-Host '- 将禁用 UWF'
    Write-Host '- 将取消保护 C:\'
    Write-Host '- 不保证自动清除所有排除项'
    Write-Host '- 重启后生效'

    if (-not (Confirm-Yes -Prompt '确认继续吗？' -Keyword 'CLEAR')) { return }

    Run-Command -Command 'uwfmgr filter disable' -IgnoreError | Out-Null
    Run-Command -Command 'uwfmgr volume unprotect C:\' -IgnoreError | Out-Null

    $Script:PendingReboot = $true
    Ask-Reboot
}

# 主流程
if (-not (Test-IsAdmin)) {
    Relaunch-AsAdmin
}

Write-Log '脚本启动'

$uwfExists = Get-Command 'uwfmgr.exe' -ErrorAction SilentlyContinue
if (-not $uwfExists) {
    Write-Host '未检测到 uwfmgr.exe，UWF 可能未安装或当前系统不可用。脚本退出。' -ForegroundColor Red
    Write-Log '未检测到 uwfmgr.exe，退出'
    exit 1
}

while ($true) {
    Show-MainMenu
    $choice = (Read-Host '请输入选项').Trim()

    switch ($choice) {
        '1' { Show-SimpleStatus; Pause-Return }
        '2' { Show-FullStatus; Pause-Return }
        '3' { Enable-RecommendedUWF; Pause-Return }
        '4' { Disable-UWF; Pause-Return }
        '5' { Set-OverlaySize; Pause-Return }
        '6' { Add-FileExclusion; Pause-Return }
        '7' { Show-Exclusions; Pause-Return }
        '8' { Remove-FileExclusion; Pause-Return }
        '9' { Create-UWFTestItems; Pause-Return }
        '10' { Check-UWFTestItems; Pause-Return }
        '11' {
            if (Confirm-Yes -Prompt '确认立即重启电脑吗？' -Keyword 'REBOOT') {
                Run-Command -Command 'shutdown /r /t 0' | Out-Null
            }
            Pause-Return
        }
        '12' { Clear-UWFConfig; Pause-Return }
        '0' {
            Write-Log '用户退出脚本'
            break
        }
        default {
            Write-Host '无效选项，请重新输入。' -ForegroundColor Yellow
            Pause-Return
        }
    }
}
