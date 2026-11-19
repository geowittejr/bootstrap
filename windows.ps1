<#
===============================================================================
 Windows bootstrap - STAGE 0 (PUBLIC)
===============================================================================
 This file is public and contains no secrets. Its only job is to get a fresh
 Windows machine far enough to clone the PRIVATE dotfiles repo, then hand off
 to windows\bootstrap.ps1 inside that repo.

 HOW TO RUN (pick one)

   A) No typing:
      1. Download this file from your site (e.g. https://<your-site>/win.ps1)
      2. In Explorer: right-click it -> Show more options -> Run with PowerShell
      3. Approve the UAC prompt, then follow the GitHub sign-in prompt.

   B) From any PowerShell window:
      powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Downloads\win.ps1"

 Safe to re-run: every step checks current state and only changes what is
 missing.

 You will be asked for your dotfiles repo (owner name/repo name or a GitHub URL). The
 answer is remembered on this machine, so re-runs just need Enter. Or pass it:
   ... -File "$HOME\Downloads\win.ps1" -Repo owner name/repo name

 WHAT IT DOES
   0. Asks which dotfiles repo to use (nothing private is stored in this file)
   1. Re-launches itself as Administrator if needed
   2. Makes sure winget is available
   3. Installs Git, GitHub CLI and PowerShell 7 (skips what is already there)
   4. Signs in to GitHub via browser/device code (skips if already signed in)
   5. Clones the private repo, or fast-forwards it if already cloned
   6. Runs <repo>\windows\bootstrap.ps1 (stage 1) under PowerShell 7

 MAINTAINER NOTES
   - Source of truth is bootstrap/windows.ps1 in the private repo. After
     editing it there, re-upload it to the website.
   - Must stay compatible with Windows PowerShell 5.1 and be ASCII-only
     (5.1 reads BOM-less files as ANSI).
   - Keep this file small and stable; put real setup logic in stage 1.
#>
[CmdletBinding()]
param(
    [string]$Repo,          # owner/name or GitHub URL; prompted for if omitted
    [string]$Branch = 'main',
    [string]$Destination,   # defaults to C:\src\<repo-name>
    [switch]$SkipStage1,
    [switch]$PauseAtEnd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-Info([string]$Message)   { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)     { Write-Host "    ok      $Message" -ForegroundColor DarkGray }
function Write-Change([string]$Message) { Write-Host "    change  $Message" -ForegroundColor Green }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs a native command with all output discarded and returns its exit code.
# (Windows PowerShell 5.1 turns redirected stderr into terminating errors when
# ErrorActionPreference is Stop, so relax it just for the call.)
function Invoke-Quiet([scriptblock]$Command) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command *> $null } finally { $ErrorActionPreference = $old }
    return $LASTEXITCODE
}

$RepoMemoryFile = Join-Path $env:LOCALAPPDATA 'dotfiles-bootstrap\repo.txt'

# Accepts owner/name, https://github.com/owner/name(.git) or git@github.com:owner/name.git
# and returns owner/name, or $null if the input is not recognized.
function ConvertTo-RepoName([string]$Value) {
    $pattern = '^\s*(?:https://github\.com/|git@github\.com:)?([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?\s*$'
    if ($Value -match $pattern) { return $Matches[1] }
    return $null
}

# Prompts for the repo (offering the last answer as the default) until valid,
# then remembers it locally for the next run.
function Resolve-RepoName([string]$Value) {
    $remembered = $null
    if (Test-Path $RepoMemoryFile) { $remembered = ConvertTo-RepoName (Get-Content $RepoMemoryFile -Raw) }
    while ($true) {
        if (-not $Value) {
            $prompt = 'Dotfiles repo (owner name/repo name or GitHub URL)'
            if ($remembered) { $prompt += " [$remembered]" }
            $Value = Read-Host $prompt
            if (-not $Value) { $Value = $remembered }
            if (-not $Value) { continue }
        }
        $name = ConvertTo-RepoName $Value
        if ($name) { break }
        Write-Warning "'$Value' is not a GitHub repo. Use owner name/repo name or https://github.com/owner/name"
        $Value = $null
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $RepoMemoryFile -Parent) | Out-Null
    Set-Content -Path $RepoMemoryFile -Value $name
    return $name
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Assert-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { Write-Ok 'winget'; return }
    Write-Change 'registering App Installer (winget)'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
    } catch {
        Write-Warning $_.Exception.Message
    }
    Update-SessionPath
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is not available. Install or update 'App Installer' from the Microsoft Store, then run this again."
    }
}

function Install-WingetPackage([string]$Id) {
    if ((Invoke-Quiet { winget list --id $Id --exact --accept-source-agreements --disable-interactivity }) -eq 0) {
        Write-Ok $Id
        return
    }
    Write-Change "installing $Id"
    winget install --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    # -1978335189 = no applicable update, -1978335135 = already installed
    if (@(0, -1978335189, -1978335135) -notcontains $LASTEXITCODE) {
        throw "winget install $Id failed (exit $LASTEXITCODE)"
    }
    Update-SessionPath
}

function Connect-GitHub {
    if ((Invoke-Quiet { gh auth status --hostname github.com }) -eq 0) {
        Write-Ok 'GitHub CLI signed in'
    } else {
        Write-Change 'signing in to GitHub - follow the prompts (a browser window will open)'
        gh auth login --hostname github.com --git-protocol https --web
        if ($LASTEXITCODE -ne 0) { throw 'gh auth login failed' }
    }
    # Make git use gh's token for https://github.com (idempotent).
    gh auth setup-git --hostname github.com
    if ($LASTEXITCODE -ne 0) { throw 'gh auth setup-git failed' }
}

function Sync-Repo {
    if (Test-Path (Join-Path $Destination '.git')) {
        $dirty = git -C $Destination status --porcelain
        if ($dirty) {
            Write-Warning "Local changes in $Destination - not pulling. Using the local copy."
            return
        }
        Write-Ok "repo present at $Destination - fast-forwarding"
        git -C $Destination pull --ff-only origin $Branch
        if ($LASTEXITCODE -ne 0) { Write-Warning 'git pull failed - continuing with the local copy.' }
        return
    }
    Write-Change "cloning $Repo to $Destination"
    New-Item -ItemType Directory -Force -Path (Split-Path $Destination -Parent) | Out-Null
    git clone --branch $Branch "https://github.com/$Repo.git" $Destination
    if ($LASTEXITCODE -ne 0) { throw "git clone of $Repo failed" }
}

function Invoke-Stage1 {
    $stage1 = Join-Path $Destination 'windows\bootstrap.ps1'
    if (-not (Test-Path $stage1)) { throw "Stage 1 script not found: $stage1" }
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path $pwsh)) { $pwsh = (Get-Command pwsh -ErrorAction Stop).Source }
    Write-Info "handing off to stage 1: $stage1"
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stage1
    if ($LASTEXITCODE -ne 0) { throw "Stage 1 failed (exit $LASTEXITCODE)" }
}

# --- main ---------------------------------------------------------------------

# Ask before elevating so the answer is passed to the elevated window.
$Repo = Resolve-RepoName $Repo
if (-not $Destination) {
    $Destination = Join-Path $env:SystemDrive ('src\' + ($Repo -split '/')[-1])
}

if (-not (Test-IsAdmin)) {
    if (-not $PSCommandPath) {
        throw 'Not running as Administrator. Open an Administrator PowerShell window and run this again.'
    }
    Write-Info 'Re-launching as Administrator...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
        '-Repo', $Repo, '-Branch', $Branch, '-Destination', "`"$Destination`"", '-PauseAtEnd')
    if ($SkipStage1) { $argList += '-SkipStage1' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($argList -join ' ')
    return
}

$exitCode = 0
try {
    Write-Info 'Checking winget'
    Assert-Winget

    Write-Info 'Installing prerequisites'
    'Git.Git', 'GitHub.cli', 'Microsoft.PowerShell' | ForEach-Object { Install-WingetPackage $_ }
    Update-SessionPath

    Write-Info 'GitHub authentication'
    Connect-GitHub

    Write-Info "Private repo ($Repo)"
    Sync-Repo

    if ($SkipStage1) {
        Write-Info "Skipping stage 1. Run it later with: pwsh -File `"$Destination\windows\bootstrap.ps1`""
    } else {
        Invoke-Stage1
    }
    Write-Info 'Stage 0 complete.'
} catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Fix the problem above and run this script again - it is safe to re-run.' -ForegroundColor Yellow
    $exitCode = 1
}

if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }
exit $exitCode
