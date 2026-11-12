# 滑洲云图 —— 工程文件关联注册脚本（T22，Windows）
#
# 作用：把 `.ovimap` 扩展名关联到 `ovimap.exe "%1"`，双击工程文件即用本程序打开。
# 特点：**只写 HKCU（当前用户）**，无需管理员权限，卸载同理。
#
# 用法（在项目根目录的 PowerShell 里执行）：
#   powershell -ExecutionPolicy Bypass -File scripts\install_association.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\install_association.ps1 -ExePath "D:\apps\ovimap\ovimap.exe"
#   powershell -ExecutionPolicy Bypass -File scripts\install_association.ps1 -Uninstall
#
# ⚠️ 本脚本在 macOS 上无法运行/验证，需在 **Windows** 上实测（见 docs/BUILD-windows.md §10）。

[CmdletBinding()]
param(
    # 卸载：删除本脚本写入的注册表项。
    [switch]$Uninstall,

    # ovimap.exe 的绝对路径。缺省时脚本会尝试在常见构建/分发目录里自动探测。
    [string]$ExePath = ""
)

$ErrorActionPreference = "Stop"

$ExtName  = ".ovimap"
$ProgId   = "OviMap.Project"
$TypeName = "滑洲云图 工程文件"
$Classes  = "HKCU:\Software\Classes"

$ExtKey      = Join-Path $Classes $ExtName
$ProgIdKey   = Join-Path $Classes $ProgId
$IconKey     = Join-Path $ProgIdKey "DefaultIcon"
$CommandKey  = Join-Path $ProgIdKey "shell\open\command"

function Remove-KeySafe([string]$path) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

# ---------------- 卸载 ----------------
if ($Uninstall) {
    Remove-KeySafe $IconKey
    Remove-KeySafe (Join-Path $ProgIdKey "shell")
    Remove-KeySafe $ProgIdKey
    Remove-KeySafe $ExtKey
    Write-Host "[ovimap] 已解除 .ovimap 关联（HKCU）。" -ForegroundColor Green
    return
}

# ---------------- 解析 exe 路径 ----------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $candidates = @(
        (Join-Path $RepoRoot "dist\ovimap-windows-x64\ovimap.exe"),
        (Join-Path $RepoRoot "build\windows\x64\runner\Release\ovimap.exe")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $ExePath = $c; break }
    }
}

if ([string]::IsNullOrWhiteSpace($ExePath)) {
    Write-Host "[ovimap] 未找到 ovimap.exe。请用 -ExePath 指定其绝对路径，例如：" -ForegroundColor Red
    Write-Host '  -ExePath "D:\apps\ovimap-windows-x64\ovimap.exe"'
    exit 1
}

if (-not (Test-Path -LiteralPath $ExePath)) {
    Write-Host "[ovimap] 指定的 exe 不存在：$ExePath" -ForegroundColor Red
    exit 1
}

$ExeFull = (Resolve-Path -LiteralPath $ExePath).Path

# ---------------- 写入注册表（HKCU，免管理员） ----------------
New-Item -Path $ExtKey -Force | Out-Null
Set-ItemProperty -Path $ExtKey -Name "(Default)" -Value $ProgId

New-Item -Path $ProgIdKey -Force | Out-Null
Set-ItemProperty -Path $ProgIdKey -Name "(Default)" -Value $TypeName

New-Item -Path $IconKey -Force | Out-Null
Set-ItemProperty -Path $IconKey -Name "(Default)" -Value ('"{0}",0' -f $ExeFull)

New-Item -Path $CommandKey -Force | Out-Null
Set-ItemProperty -Path $CommandKey -Name "(Default)" -Value ('"{0}" "%1"' -f $ExeFull)

Write-Host "[ovimap] 已注册 .ovimap 关联（HKCU）：" -ForegroundColor Green
Write-Host "  打开方式 = $ExeFull"
Write-Host "  图标     = $ExeFull,0"
Write-Host ""
Write-Host "提示：若资源管理器未立即生效，注销/重启或执行："
Write-Host '  taskkill /F /IM explorer.exe; start explorer.exe'
Write-Host "卸载：powershell -ExecutionPolicy Bypass -File scripts\install_association.ps1 -Uninstall"
