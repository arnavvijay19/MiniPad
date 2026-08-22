<#
.SYNOPSIS
    Download the newest MiniPad .ipa built by GitHub Actions, verify it, and
    hand it to Sideloadly.

.DESCRIPTION
    Everything between "CI is green" and "the installer is open with the right
    file" is mechanical, so this does it: find the newest successful iOS CI run
    on the branch, download the ipa artifact, verify its SHA-256 against the
    checksum CI recorded, and open Sideloadly with the file selected.

    Signing itself is not automated and deliberately so. It needs your Apple ID
    and, on first use, a 2FA code. Those belong on this machine, typed into
    Sideloadly, and nowhere else — never in the repository and never in GitHub
    Actions.

.PARAMETER Variant
    PersonalFree (default) strips the share extension, widget and File Provider.
    Those need an App Group, which a free Apple ID cannot register, and each is
    a separate App ID against your 10-per-week limit. Full keeps them; use it
    only with a paid Apple Developer Program membership.

.PARAMETER Token
    A GitHub token with `actions:read` on the repository. Defaults to
    `gh auth token` if the GitHub CLI is signed in, else $env:GITHUB_TOKEN.
    Artifacts cannot be downloaded anonymously even from a public repository.

.EXAMPLE
    .\Get-MiniPadIPA.ps1
    .\Get-MiniPadIPA.ps1 -Variant Full -OutDir D:\ipa -NoLaunch
#>
[CmdletBinding()]
param(
    [ValidateSet('PersonalFree', 'Full')]
    [string]$Variant = 'PersonalFree',
    [string]$Repo    = 'arnavvijay19/MiniPad',
    [string]$Branch  = 'claude/pre-mac-ipad-ready',
    [string]$OutDir  = "$env:USERPROFILE\Downloads\MiniPad",
    [string]$Token,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Warn { param($Message) Write-Host "    $Message" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------
if (-not $Token) {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $Token = (gh auth token 2>$null)
    }
    if (-not $Token) { $Token = $env:GITHUB_TOKEN }
}
if (-not $Token) {
    throw @"
No GitHub token. Artifacts are not downloadable anonymously, even from a public
repository. Either:
    winget install GitHub.cli ; gh auth login
or create a fine-grained token with Actions: read and pass -Token <value>.
"@
}
$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

# ---------------------------------------------------------------------------
# Newest successful run on the branch
# ---------------------------------------------------------------------------
Write-Step "Looking for the newest green iOS CI run on $Branch"
$runsUrl = "https://api.github.com/repos/$Repo/actions/workflows/ios-ci.yml/runs" +
           "?branch=$Branch&status=success&per_page=1"
$runs = Invoke-RestMethod -Uri $runsUrl -Headers $headers

if (-not $runs.workflow_runs -or $runs.workflow_runs.Count -eq 0) {
    throw "No successful iOS CI run on $Branch yet. Check https://github.com/$Repo/actions"
}
$run = $runs.workflow_runs[0]
Write-Host "    run #$($run.run_number)  $($run.head_sha.Substring(0,12))  $($run.created_at)"

# ---------------------------------------------------------------------------
# The ipa artifact
# ---------------------------------------------------------------------------
$artifacts = Invoke-RestMethod -Uri $run.artifacts_url -Headers $headers
$artifact  = $artifacts.artifacts | Where-Object { $_.name -eq 'ipa' } | Select-Object -First 1
if (-not $artifact) {
    throw "That run produced no 'ipa' artifact. It may have been a docs-only run, or the artifact has expired (they are kept 14 days)."
}
if ($artifact.expired) { throw "The artifact has expired. Re-run the workflow." }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zipPath = Join-Path $OutDir "ipa-$($run.head_sha.Substring(0,12)).zip"

Write-Step "Downloading $([math]::Round($artifact.size_in_bytes / 1MB, 1)) MB"
Invoke-WebRequest -Uri $artifact.archive_download_url -Headers $headers -OutFile $zipPath

$extractDir = Join-Path $OutDir $run.head_sha.Substring(0, 12)
if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
Remove-Item $zipPath

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
$name = if ($Variant -eq 'PersonalFree') { 'MiniPad-PersonalFree-unsigned.ipa' }
        else { 'MiniPad-unsigned.ipa' }
$ipa = Join-Path $extractDir $name
if (-not (Test-Path $ipa)) {
    throw "$name is not in the artifact. Found: $((Get-ChildItem $extractDir).Name -join ', ')"
}

Write-Step "Verifying checksum"
$sumFile = "$ipa.sha256"
if (Test-Path $sumFile) {
    $expected = ((Get-Content $sumFile -Raw).Trim() -split '\s+')[0]
    $actual   = (Get-FileHash -Algorithm SHA256 $ipa).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) {
        throw "Checksum mismatch.`n  expected $expected`n  got      $actual"
    }
    Write-Host "    sha256 $actual  OK"
} else {
    Write-Warn "No .sha256 alongside the ipa — skipping verification."
}

$sizeMB = [math]::Round((Get-Item $ipa).Length / 1MB, 1)
Write-Host ""
Write-Host "  $ipa" -ForegroundColor Green
Write-Host "  $sizeMB MB   variant: $Variant   commit: $($run.head_sha.Substring(0,12))"
Write-Host ""

# ---------------------------------------------------------------------------
# Hand it to Sideloadly
# ---------------------------------------------------------------------------
$sideloadly = @(
    "$env:ProgramFiles\Sideloadly\sideloadly.exe",
    "${env:ProgramFiles(x86)}\Sideloadly\sideloadly.exe",
    "$env:LOCALAPPDATA\Programs\Sideloadly\sideloadly.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

Write-Step "Next: sign and install"
Write-Host @"
    1. Connect the iPad by USB and trust this computer.
    2. In Sideloadly: drop in the .ipa above, enter your Apple ID, Start.
       Use an app-specific password if your Apple ID has 2FA
       (https://account.apple.com -> Sign-In and Security -> App-Specific Passwords).
    3. On the iPad: Settings -> General -> VPN & Device Management ->
       trust your developer certificate. This step is required once per
       certificate and cannot be automated from here.

    The signature lasts 7 days. Re-run this script and repeat step 2 before it
    expires, or install SideStore so the iPad refreshes itself — see
    docs/design/unified-agent/PRE_MAC_HANDOFF.md section 3.
"@

if ($sideloadly -and -not $NoLaunch) {
    Write-Step "Opening Sideloadly"
    Start-Process -FilePath $sideloadly
    Start-Process -FilePath (Split-Path $ipa)     # Explorer, ready to drag from
} elseif (-not $sideloadly) {
    Write-Warn "Sideloadly not found. Install it with:  winget install iOSGods.Sideloadly"
    Write-Warn "or download it from https://sideloadly.io"
}
