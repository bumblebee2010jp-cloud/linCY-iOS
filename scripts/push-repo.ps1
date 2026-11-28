<#
.SYNOPSIS
    把当前目录的工程推到 GitHub，并触发一次 unsigned-ipa 构建。

.DESCRIPTION
    首次运行会 init 仓库、提交、推送；之后每次运行只提交改动并推送。
    push 到 tag 会额外生成 Release（手机上可直接点链接下载 ipa）。

.EXAMPLE
    .\push-repo.ps1 -RepoUrl https://github.com/YOURNAME/linCY-iOS.git

.EXAMPLE
    # 推一个 tag，触发 Release 产物
    .\push-repo.ps1 -RepoUrl https://github.com/YOURNAME/linCY-iOS.git -Tag v0.1.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoUrl,
    [string]$Message = 'build: 更新源码',
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw '未找到 git，先装 Git for Windows 并确保在 PATH 里。'
}

if (-not (Test-Path '.git')) {
    Write-Host '[init] 初始化仓库...' -ForegroundColor Cyan
    git init | Out-Null
    git branch -M main
}

if (-not (git remote 2>$null)) {
    Write-Host "[init] 添加远端: $RepoUrl" -ForegroundColor Cyan
    git remote add origin $RepoUrl
} else {
    $cur = (git remote get-url origin)
    if ($cur -ne $RepoUrl) {
        Write-Host "[init] 更新远端: $cur → $RepoUrl" -ForegroundColor Cyan
        git remote set-url origin $RepoUrl
    }
}

git add -A
$staged = git status --porcelain
if ($staged) {
    git -c user.name='linCY' -c user.email='linCY@local' commit -m $Message | Out-Null
    Write-Host '[commit] 已提交改动' -ForegroundColor Cyan
} else {
    Write-Host '[commit] 没有新改动' -ForegroundColor Yellow
}

Write-Host '[push] 推送 main...' -ForegroundColor Cyan
git push -u origin main

if ($Tag) {
    Write-Host "[tag] $Tag" -ForegroundColor Cyan
    git tag -f $Tag
    git push -f origin $Tag
    Write-Host "Release 构建已触发，几分钟后到 Actions / Releases 页面取 ipa。" -ForegroundColor Green
} else {
    Write-Host 'push 完成。到仓库 Actions 页面点 unsigned-ipa → Run workflow 触发构建。' -ForegroundColor Green
}

Write-Host @'

提示：
  - 私有仓库的 macOS runner 按 10 倍消耗分钟数，免费额度约 200 macOS 分钟/月。
  - 公开仓库的 macOS runner 免费且不限次数。
'@ -ForegroundColor DarkGray
