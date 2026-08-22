<#
.SYNOPSIS
    Add an entry to docs/design/unified-agent/DEVICE_LOG.md, then commit and push it.

.DESCRIPTION
    Asks a handful of questions, writes the entry at the top of the Entries
    section, and offers to push. Everything is optional — press Enter to leave
    a field as "?". A half-filled entry is worth more than none.

    It fills in what it can on its own: today's date, and the build id taken
    from a MiniPad-PersonalFree-adhoc.ipa.sha256 sitting next to the script or
    in the current folder.

.PARAMETER Broke
    Use the "it broke" template instead of the "it worked" one.

.EXAMPLE
    .\Add-DeviceLogEntry.ps1
    .\Add-DeviceLogEntry.ps1 -Broke
#>
[CmdletBinding()]
param(
    [switch]$Broke,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

# --- locate the repo and the log -------------------------------------------
if (-not $RepoRoot) {
    $RepoRoot = (git rev-parse --show-toplevel 2>$null)
    if (-not $RepoRoot) { $RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path }
}
$Log = Join-Path $RepoRoot 'docs\design\unified-agent\DEVICE_LOG.md'
if (-not (Test-Path $Log)) { throw "DEVICE_LOG.md not found at $Log" }

function Ask($prompt, $default = '?') {
    $answer = Read-Host "  $prompt"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return $answer.Trim()
}

function AskParagraph($prompt) {
    Write-Host "  $prompt (blank line to finish)" -ForegroundColor Cyan
    $lines = @()
    while ($true) {
        $l = Read-Host '  >'
        if ([string]::IsNullOrWhiteSpace($l)) { break }
        $lines += "  $l"
    }
    if ($lines.Count -eq 0) { return '  ?' }
    return ($lines -join "`n")
}

# --- what we can work out ourselves ----------------------------------------
$date = Get-Date -Format 'yyyy-MM-dd'

$build = '?'
$sumFile = Get-ChildItem -Path $PSScriptRoot, (Get-Location) -Filter 'MiniPad-PersonalFree-adhoc.ipa.sha256' `
           -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sumFile) {
    $build = ((Get-Content $sumFile.FullName -Raw).Trim() -split '\s+')[0].Substring(0, 8)
    Write-Host "Build id from $($sumFile.Name): $build" -ForegroundColor DarkGray
}

Write-Host ''
# if/else rather than the ?: ternary: that operator is PowerShell 7+, and
# Windows still ships 5.1 as the default shell.
if ($Broke) {
    Write-Host 'Recording something that broke.' -ForegroundColor Yellow
} else {
    Write-Host 'Recording something that worked.' -ForegroundColor Yellow
}
Write-Host 'Press Enter to leave any field unknown.' -ForegroundColor DarkGray
Write-Host ''

$title  = Ask 'One line: what did you try?' 'untitled'
$build  = Ask "Build id [$build]" $build
$ipados = Ask 'iPadOS version'

if ($Broke) {
    Write-Host ''
    $did      = AskParagraph 'What did you do? Exact steps, or the exact prompt you typed.'
    Write-Host ''
    $happened = AskParagraph 'What happened instead?'
    Write-Host ''
    $crash    = Ask 'Crash log: attached / none - it hung / none - it misbehaved' 'none - not captured'
} else {
    Write-Host ''
    $happened = AskParagraph 'What happened?'
    Write-Host ''
    Write-Host '  Numbers — Enter to skip each' -ForegroundColor Cyan
    $model    = Ask 'model'
    $dl       = Ask 'download time'
    $load     = Ask 'load time'
    $toks     = Ask 'generation tok/s'
    $p1       = Ask 'prompt tokens, turn 1'
    $p2       = Ask 'prompt tokens, turn 2 (after a tool call)'
}

Write-Host ''
Write-Host '  Diagnostics screen (Settings -> Agent)' -ForegroundColor Cyan
$inference = Ask 'On-device inference: available / unavailable: <reason>'
$storage   = Ask 'Workspace storage: app sandbox / shared container'

# --- build the entry --------------------------------------------------------
if ($Broke) {
    $entry = @"
### $date — $title

Build:    $build
Variant:  PersonalFree adhoc
iPadOS:   $ipados

What I did:
$did

What happened instead:
$happened

Crash log:  $crash
Diagnostics screen:
  On-device inference    $inference
  Workspace storage      $storage

"@
} else {
    $entry = @"
### $date — $title

Build:    $build
Variant:  PersonalFree adhoc
iPadOS:   $ipados

What happened:
$happened

Numbers:
  model                  $model
  download time          $dl
  load time              $load
  generation tok/s       $toks
  prompt tokens turn 1   $p1
  prompt tokens turn 2   $p2

Diagnostics screen:
  On-device inference    $inference
  Workspace storage      $storage

"@
}

# --- insert at the top of Entries ------------------------------------------
$content = Get-Content $Log -Raw
$marker  = '_Newest first._'
if ($content -notmatch [regex]::Escape($marker)) { throw "Couldn't find the Entries marker in DEVICE_LOG.md" }

# .Replace(), not -replace. The latter is a regex operator and treats `$` in
# the *replacement* as a capture-group reference, so an entry mentioning a
# price, a shell variable or a Swift string interpolation would come out
# mangled. .Replace() is literal on both sides.
$placeholder = '_Nothing recorded yet. The app has never run on hardware._'
$content = $content.Replace($placeholder, '').TrimEnd() + "`n"

$content = $content.Replace($marker, "$marker`n`n$entry")
# Not Set-Content -Encoding UTF8: on PowerShell 5.1 that writes a BOM, which
# shows up as stray characters at the top of the rendered markdown.
[System.IO.File]::WriteAllText($Log, $content, (New-Object System.Text.UTF8Encoding $false))

Write-Host ''
Write-Host "Added to $Log" -ForegroundColor Green
Write-Host ''
Write-Host $entry -ForegroundColor DarkGray

# --- commit and push --------------------------------------------------------
$answer = Read-Host 'Commit and push this? [Y/n]'
if ($answer -match '^(n|no)$') {
    Write-Host 'Left uncommitted. `git add` and commit when you are ready.' -ForegroundColor Yellow
    exit 0
}

Push-Location $RepoRoot
try {
    git add 'docs/design/unified-agent/DEVICE_LOG.md'
    git commit -m "device log: $title" | Out-Null
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    Write-Host "Pushing to $branch ..." -ForegroundColor Cyan
    git pull --rebase origin $branch
    git push origin $branch
    Write-Host 'Pushed. The other session can read it now.' -ForegroundColor Green
} finally {
    Pop-Location
}
