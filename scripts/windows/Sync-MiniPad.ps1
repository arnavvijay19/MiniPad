<#
.SYNOPSIS
    Catch up: pull, show what the cloud session left for you, and fetch the
    newest signed .ipa if it changed.

.DESCRIPTION
    One command to run at the start of a local session, and again whenever the
    cloud session says it has pushed something.

    It does four things:
      1. git pull --rebase (never force, never clobber - the two sessions share
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
    # Defaults to <repo>/builds, resolved after the repo root is known. The
    # previous default was $env:USERPROFILE\Downloads\MiniPad, which assumed a
    # layout this machine does not have - the checkout is not under the user
    # profile at all. Repo-relative is correct on any machine, and *.ipa is
    # already gitignored so nothing here can be committed by accident.
    [string]$OutDir,
    [string]$Token
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 negotiates TLS 1.0 by default; github.com refuses it.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
# The console starts in the OEM codepage (IBM437 on this machine), which has no
# em dash and no arrows - every one in HANDOFF.md printed as a replacement
# character even after the file was decoded correctly. Rendering and decoding
# are separate problems; this is the rendering half.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
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
    # Capture it now: the rev-parse below is itself a native command and resets
    # $LASTEXITCODE, so reading it later reports the wrong code (0, i.e. success).
    $pullExit = $LASTEXITCODE
    $after = (git rev-parse HEAD).Trim()
    if ($pullExit -ne 0) {
        # HEAD is unchanged when the pull fails too, so the equality check below
        # reported "already up to date" for a rebase that refused to start -
        # the queue printed after this would be silently stale.
        Warn "git pull --rebase FAILED (exit $pullExit) - you are NOT synced."
        Warn 'Commit or stash your changes, then run this again.'
        Warn 'Everything below may be out of date.'
    } elseif ($before -eq $after) {
        Write-Host "    already up to date"
    } else {
        Write-Host "    new commits:" -ForegroundColor Green
        git log --oneline "$before..$after" | ForEach-Object { Write-Host "      $_" }
    }

    # --- 2. what is waiting for you -----------------------------------------
    $handoff = Join-Path $root 'docs\design\unified-agent\HANDOFF.md'
    if (Test-Path $handoff) {
        # -Encoding UTF8 is required: 5.1's Get-Content defaults to the ANSI
        # codepage, so every multi-byte character in HANDOFF.md came back as
        # mojibake ("2026-08-19 A. First install"). 7.x defaults to UTF-8 and
        # would have hidden this.
        $lines = Get-Content $handoff -Encoding UTF8
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

if (-not $OutDir) { $OutDir = Join-Path $root 'builds' }

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

# Name the folder after the commit the .ipa was BUILT from, not the commit that
# signed it. Those differ whenever the source went green on another branch: the
# signing run rides on this branch's HEAD while the app inside is an entirely
# different commit. A folder named for the signing commit says the build is
# something it is not, which is the exact class of bug the branch-filter fix
# addressed on the CI side.
#
# The source sha lives in BUILD-INFO.txt inside the artifact, so it is not
# knowable until after the download. The signing run id IS knowable now, and is
# recorded in every folder we have already unpacked - so "do I have this
# already" is answered by searching those, not by guessing a folder name.
# Match on signing_run, not ios_ci_run: re-signing the same source produces a
# new signing run and a genuinely new .ipa, and the user has to re-sideload it.
$existing = Get-ChildItem $OutDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'BUILD-INFO.txt') } |
    Where-Object {
        (Get-Content (Join-Path $_.FullName 'BUILD-INFO.txt') -Encoding UTF8) -match "^signing_run: $($run.id)$"
    } | Select-Object -First 1

if ($existing) {
    Write-Host "    already downloaded: $($existing.FullName)" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Nothing new to install.' -ForegroundColor Green
    exit 0
}

Step "Downloading $([math]::Round($artifact.size_in_bytes / 1MB, 1)) MB"
$zip     = Join-Path $OutDir "ipa-adhoc-$($run.id).zip"
$staging = Join-Path $OutDir ".staging-$($run.id)"
Invoke-WebRequest -Uri $artifact.archive_download_url -Headers $headers -OutFile $zip
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
Expand-Archive -Path $zip -DestinationPath $staging -Force
Remove-Item $zip

# Read the provenance before deciding where this lands.
$infoPath = Join-Path $staging 'BUILD-INFO.txt'
if (Test-Path $infoPath) {
    $info   = Get-Content $infoPath -Encoding UTF8
    $srcSha = ($info | Where-Object { $_ -match '^source_sha: ' }) -replace '^source_sha: ', ''
    $srcBr  = ($info | Where-Object { $_ -match '^source_branch: ' }) -replace '^source_branch: ', ''
} else {
    # An .ipa signed before the workflow emitted provenance. Fall back to the
    # old behaviour rather than failing, but say so - the folder name is a
    # guess in this case, and a wrong guess is what we are trying to stop.
    Warn 'No BUILD-INFO.txt in the artifact (signed before provenance was added).'
    Warn 'Falling back to the signing commit for the folder name, which may not'
    Warn 'be the commit this build was made from.'
    $srcSha = $run.head_sha
    $srcBr  = $run.head_branch
}

$stamp   = $srcSha.Substring(0, 8)
$destDir = Join-Path $OutDir $stamp
$ipa     = Join-Path $destDir 'MiniPad-PersonalFree-adhoc.ipa'
if (Test-Path $destDir) { Remove-Item -Recurse -Force $destDir }
Move-Item $staging $destDir

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
} else { Warn 'No .sha256 beside the ipa - skipped verification.' }

Write-Host ''
Write-Host "  NEW BUILD: $ipa" -ForegroundColor Green
Write-Host "  built from $stamp ($srcBr)   $([math]::Round((Get-Item $ipa).Length / 1MB, 1)) MB"
Write-Host ''
Write-Host '  Re-sideload it: drop it into Sideloadly, same Apple ID, Start.' -ForegroundColor Cyan
Write-Host '  Then record what it does with .\scripts\windows\Add-DeviceLogEntry.ps1' -ForegroundColor Cyan
