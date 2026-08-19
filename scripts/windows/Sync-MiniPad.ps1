<#
.SYNOPSIS
    Catch up: pull, show what the cloud session left for you, and fetch the
    newest signed .ipa if it changed.

.DESCRIPTION
    One command to run at the start of a local session, and again whenever the
    cloud session says it has pushed something.

    It does four things:
      1. git pull --rebase (never force, never clobber — the two sessions share
         this branch)
      2. prints the open items from the "For the local session" section of
         HANDOFF.md
      3. finds the newest successful "Ad-hoc sign IPA" run and, if its .ipa
         differs from the one you already have, downloads and verifies it
      4. tells you whether you need to re-sideload

.PARAMETER NoDownload
    Skip the artifact download. Just sync the repo and show the queue.

.EXAMPLE
    .\Sync-MiniPad.ps1
    .\Sync-MiniPad.ps1 -NoDownload
#>
[CmdletBinding()]
param(
    [switch]$NoDownload,
    [string]$Repo   = 'arnavvijay19/MiniPad',
    [string]$Branch = 'claude/pre-mac-ipad-ready',
    [string]$OutDir = "$env:USERPROFILE\Downloads\MiniPad",
    [string]$Token
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 negotiates TLS 1.0 by default; github.com refuses it.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
# 5.1's Invoke-WebRequest progress bar makes a 40 MB download take minutes.
$ProgressPreference = 'SilentlyContinue'
# PowerShell 7.4 turns git's ordinary progress chatter on stderr into a
# terminating error. It is not one.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

# --- 1. sync the repo -------------------------------------------------------
$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) { $root = (Resolve-Path "$PSScriptRoot\..\..").Path }
Push-Location $root
try {
    Step "Syncing $Branch"
    $before = (git rev-parse HEAD).Trim()
    git pull --rebase origin $Branch
    $after = (git rev-parse HEAD).Trim()
    if ($before -eq $after) {
        Write-Host "    already up to date"
    } else {
        Write-Host "    new commits:" -ForegroundColor Green
        git log --oneline "$before..$after" | ForEach-Object { Write-Host "      $_" }
    }

    # --- 2. what is waiting for you -----------------------------------------
    $handoff = Join-Path $root 'docs\design\unified-agent\HANDOFF.md'
    if (Test-Path $handoff) {
        $lines = Get-Content $handoff
        $start = ($lines | Select-String -SimpleMatch '## For the local session' | Select-Object -First 1).LineNumber
        $end   = ($lines | Select-String -SimpleMatch '## For the cloud session' | Select-Object -First 1).LineNumber
        if ($start -and $end -and $end -gt $start) {
            $section = $lines[$start..($end - 2)]
            $open = $section | Where-Object { $_ -match '^\s*- \[ \]' }
            Write-Host ''
            if ($open) {
                Step "Waiting for you ($($open.Count) open)"
                # Print each item with its indented continuation lines.
                $printing = $false
                foreach ($l in $section) {
                    if ($l -match '^\s*- \[ \]') { $printing = $true }
                    elseif ($l -match '^\s*- \[x\]') { $printing = $false }
                    elseif ($l -match '^\S' -and $l -notmatch '^\s') { $printing = $false }
                    if ($printing) { Write-Host "    $l" }
                }
            } else {
                Step 'Nothing waiting for you in HANDOFF.md'
            }
        }
    }
} finally { Pop-Location }

if ($NoDownload) { Write-Host ''; Write-Host 'Done (skipped the download).' -ForegroundColor Green; exit 0 }

# --- 3. newest signed ipa ---------------------------------------------------
if (-not $Token) {
    if (Get-Command gh -ErrorAction SilentlyContinue) { $Token = (gh auth token 2>$null) }
    if (-not $Token) { $Token = $env:GITHUB_TOKEN }
}
if (-not $Token) {
    Write-Host ''
    Warn 'No GitHub token, so I cannot check for a new build.'
    Warn 'Run `gh auth login`, or pass -Token. Repo sync above still worked.'
    exit 0
}
$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

Write-Host ''
Step 'Looking for the newest signed .ipa'
$runsUrl = "https://api.github.com/repos/$Repo/actions/workflows/adhoc-sign-ipa.yml/runs" +
           "?branch=$Branch&status=success&per_page=1"
$runs = Invoke-RestMethod -Uri $runsUrl -Headers $headers
if (-not $runs.workflow_runs -or $runs.workflow_runs.Count -eq 0) {
    Warn "No successful 'Ad-hoc sign IPA' run on $Branch yet."
    Warn "Check https://github.com/$Repo/actions"
    exit 0
}
$run = $runs.workflow_runs[0]
Write-Host "    run #$($run.run_number)  $($run.head_sha.Substring(0,8))  $($run.created_at)"

$artifacts = Invoke-RestMethod -Uri $run.artifacts_url -Headers $headers
$artifact  = $artifacts.artifacts | Where-Object { $_.name -eq 'ipa-adhoc' } | Select-Object -First 1
if (-not $artifact) { Warn "That run produced no 'ipa-adhoc' artifact."; exit 0 }
if ($artifact.expired)  { Warn 'The artifact has expired (they last 14 days). Re-run the workflow.'; exit 0 }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp   = $run.head_sha.Substring(0, 8)
$destDir = Join-Path $OutDir $stamp
$ipa     = Join-Path $destDir 'MiniPad-PersonalFree-adhoc.ipa'

if (Test-Path $ipa) {
    Write-Host "    already downloaded: $ipa" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Nothing new to install.' -ForegroundColor Green
    exit 0
}

Step "Downloading $([math]::Round($artifact.size_in_bytes / 1MB, 1)) MB"
$zip = Join-Path $OutDir "ipa-adhoc-$stamp.zip"
Invoke-WebRequest -Uri $artifact.archive_download_url -Headers $headers -OutFile $zip
if (Test-Path $destDir) { Remove-Item -Recurse -Force $destDir }
Expand-Archive -Path $zip -DestinationPath $destDir -Force
Remove-Item $zip

if (-not (Test-Path $ipa)) {
    Warn "MiniPad-PersonalFree-adhoc.ipa not in the artifact. Found: $((Get-ChildItem $destDir).Name -join ', ')"
    exit 1
}

Step 'Verifying'
$sumFile = "$ipa.sha256"
if (Test-Path $sumFile) {
    $expected = ((Get-Content $sumFile -Raw).Trim() -split '\s+')[0]
    $actual   = (Get-FileHash -Algorithm SHA256 $ipa).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) { throw "Checksum mismatch.`n  expected $expected`n  got      $actual" }
    Write-Host "    sha256 $actual  OK"
} else { Warn 'No .sha256 beside the ipa — skipped verification.' }

Write-Host ''
Write-Host "  NEW BUILD: $ipa" -ForegroundColor Green
Write-Host "  commit $stamp   $([math]::Round((Get-Item $ipa).Length / 1MB, 1)) MB"
Write-Host ''
Write-Host '  Re-sideload it: drop it into Sideloadly, same Apple ID, Start.' -ForegroundColor Cyan
Write-Host '  Then record what it does with .\scripts\windows\Add-DeviceLogEntry.ps1' -ForegroundColor Cyan
