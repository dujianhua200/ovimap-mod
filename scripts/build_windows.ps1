# ============================================================================
#  滑洲云图 ovimap —— Windows 一键构建脚本（Release）
#
#  用法（在项目根目录的 PowerShell 中执行）：
#      powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
#  或直接双击 scripts\build_windows.bat
#
#  前置：Windows 10/11 + Flutter SDK(stable) + Visual Studio 2022（含
#        「使用 C++ 的桌面开发」工作负载）。首次安装详见 docs\BUILD-windows.md。
# ============================================================================

$ErrorActionPreference = 'Stop'

# 切到仓库根目录（脚本位于 <root>\scripts\）
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Fail([string]$msg) {
    Write-Host ""
    Write-Host "[失败] $msg" -ForegroundColor Red
    exit 1
}

# ---- 1. 检测 Flutter --------------------------------------------------------
Write-Step "检测 Flutter SDK"
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if ($null -eq $flutter) {
    Write-Host ""
    Write-Host "未检测到 Flutter。请先安装：" -ForegroundColor Yellow
    Write-Host "  1) 下载 Flutter SDK (stable): https://docs.flutter.dev/get-started/install/windows"
    Write-Host "  2) 解压到 C:\src\flutter（路径不要含中文/空格）"
    Write-Host "  3) 把 C:\src\flutter\bin 加入系统环境变量 PATH"
    Write-Host "  4) 重新打开终端，运行 flutter doctor 确认无红叉"
    Write-Host ""
    Write-Host "详细图文步骤见 docs\BUILD-windows.md"
    exit 1
}

# ---- 2. 校验 Flutter 版本 ---------------------------------------------------
Write-Step "校验 Flutter 版本"
$versionLine = (& flutter --version | Select-Object -First 1)
Write-Host "  $versionLine"
if ($versionLine -match 'Flutter\s+(\d+)\.(\d+)') {
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 35)) {
        Fail "Flutter 版本过低（需 >= 3.35，本项目基线 3.47.2）。请升级：flutter upgrade"
    }
} else {
    Write-Host "  [警告] 无法解析版本号，继续尝试构建。" -ForegroundColor Yellow
}

# ---- 3. 启用 Windows 桌面支持 ----------------------------------------------
Write-Step "启用 Windows 桌面支持"
& flutter config --enable-windows-desktop | Out-Null

# ---- 4. 检查 Visual Studio C++ 工作负载 ------------------------------------
Write-Step "检查 Visual Studio / C++ 工具链"
$doctor = (& flutter doctor -v 2>&1 | Out-String)
if ($doctor -match 'Visual Studio' -and $doctor -match 'Unable to find|not installed|✗') {
    Write-Host ""
    Write-Host "[警告] 未检测到可用的 Visual Studio C++ 工具链。" -ForegroundColor Yellow
    Write-Host "  请安装 Visual Studio 2022 Community，并勾选工作负载：" -ForegroundColor Yellow
    Write-Host "    「使用 C++ 的桌面开发 / Desktop development with C++」"
    Write-Host "  安装后运行 flutter doctor 确认 Visual Studio 一栏为 √。"
    Write-Host ""
}

# ---- 5. 拉取依赖 ------------------------------------------------------------
Write-Step "flutter pub get"
& flutter pub get
if ($LASTEXITCODE -ne 0) { Fail "flutter pub get 失败（请检查网络/依赖）。" }

# ---- 6. 构建 Release --------------------------------------------------------
Write-Step "flutter build windows --release"
& flutter build windows --release
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "----- flutter doctor -v（排错摘要）-----" -ForegroundColor Yellow
    & flutter doctor -v
    Fail "Windows 构建失败。请对照上面的 flutter doctor 输出排查。"
}

# ---- 7. 复制产物到可分发目录 ------------------------------------------------
Write-Step "整理分发产物"
$releaseDir = Join-Path $root "build\windows\x64\runner\Release"
$exePath = Join-Path $releaseDir "ovimap.exe"
if (-not (Test-Path $exePath)) {
    Fail "未找到构建产物：$exePath"
}

$distDir = Join-Path $root "dist\ovimap-windows-x64"
if (Test-Path $distDir) { Remove-Item $distDir -Recurse -Force }
New-Item -ItemType Directory -Path $distDir | Out-Null
Copy-Item (Join-Path $releaseDir '*') $distDir -Recurse -Force

# ---- 8. 完成 ----------------------------------------------------------------
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host " 构建成功！" -ForegroundColor Green
Write-Host "---------------------------------------------------------"
Write-Host " 可执行文件：$exePath"
Write-Host " 分发副本  ：$distDir"
Write-Host ""
Write-Host " 绿色版说明：把 dist\ovimap-windows-x64 整个文件夹拷到任意位置，"
Write-Host " 双击 ovimap.exe 即可运行；数据落在 %APPDATA%\ovimap（与程序目录分离）。"
Write-Host " 目标机需具备 Microsoft Visual C++ 2015-2022 运行库(x64)（Win10/11 通常自带）。"
Write-Host "=========================================================" -ForegroundColor Green
