<#
.SYNOPSIS
    在 Windows 本地用 zsign 给未签名 ipa 重签名，并自检产物。

.DESCRIPTION
    需要 zsign.exe。下载：https://github.com/zhlynn/zsign/releases
    放到 PATH 或本脚本同目录。

.EXAMPLE
    .\sign-ipa.ps1 -Ipa .\linCY-0.1.0-1-Release-unsigned.ipa `
                   -P12 .\cert.p12 -P12Password '你的密码' `
                   -Profile .\profile.mobileprovision

.EXAMPLE
    # 顺带改 bundle id（必须与描述文件里的 App ID 匹配，或是通配符 profile）
    .\sign-ipa.ps1 -Ipa .\app.ipa -P12 .\cert.p12 -P12Password 'pwd' `
                   -Profile .\profile.mobileprovision -BundleId com.yourname.linCY
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Ipa,
    [Parameter(Mandatory = $true)][string]$P12,
    [Parameter(Mandatory = $true)][string]$P12Password,
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$BundleId,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

function Resolve-File([string]$p, [string]$label) {
    if (-not (Test-Path -LiteralPath $p)) { throw "$label 不存在: $p" }
    return (Resolve-Path -LiteralPath $p).Path
}

$Ipa     = Resolve-File $Ipa     'ipa'
$P12     = Resolve-File $P12     'p12 证书'
$Profile = Resolve-File $Profile '描述文件'

if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $Ipa) 'signed' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

# 找 zsign
$zsign = $null
$cmd = Get-Command zsign -ErrorAction SilentlyContinue
if ($cmd) { $zsign = $cmd.Source }
if (-not $zsign) {
    $local = Join-Path $PSScriptRoot 'zsign.exe'
    if (Test-Path $local) { $zsign = $local }
}
if (-not $zsign) {
    throw "未找到 zsign。从 https://github.com/zhlynn/zsign/releases 下载 zsign.exe 放到 $PSScriptRoot 或加入 PATH。"
}
Write-Host "zsign: $zsign" -ForegroundColor Cyan

$name = [IO.Path]::GetFileNameWithoutExtension($Ipa) -replace '-unsigned$', ''
$out  = Join-Path $OutDir "$name-signed.ipa"

$zargs = @('-k', $P12, '-p', $P12Password, '-m', $Profile, '-o', $out)
if ($BundleId) { $zargs += @('-b', $BundleId) }
$zargs += $Ipa

Write-Host "`n[1/3] 签名中..." -ForegroundColor Cyan
& $zsign @zargs
if ($LASTEXITCODE -ne 0) { throw "zsign 退出码 $LASTEXITCODE，签名失败。密码错误 / 证书与 profile 不匹配是最常见原因。" }

if (-not (Test-Path $out)) { throw "zsign 声称成功但没有产出 $out" }
Write-Host "已生成: $out" -ForegroundColor Green

Write-Host "`n[2/3] 校验签名信息..." -ForegroundColor Cyan
& $zsign '-t' $out

Write-Host "`n[3/3] 结构校验..." -ForegroundColor Cyan
$pyExe = $null
foreach ($cand in @('python', 'python3', 'py')) {
    $c = Get-Command $cand -ErrorAction SilentlyContinue
    if ($c) { $pyExe = $c.Source; break }
}
$checker = Join-Path $PSScriptRoot 'check_ipa.py'
if ($pyExe -and (Test-Path $checker)) {
    & $pyExe $checker $out
} else {
    Write-Host "跳过（未找到 python 或 check_ipa.py）" -ForegroundColor Yellow
}

Write-Host @"

完成。
  产物 : $out
  大小 : $([math]::Round((Get-Item $out).Length / 1MB, 2)) MiB

安装方式（任选）：
  1. 爱思助手：把 ipa 拖进主界面 → 安装
  2. Apple 设备管理：设备 → 右键 → 安装 App
  3. 命令行（需 libimobiledevice）：ideviceinstaller -i "$out"
"@ -ForegroundColor Green
