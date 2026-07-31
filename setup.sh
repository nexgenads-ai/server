#Requires -Version 5.0

# ==========================================================
# NexGenAds SSH Setup (Windows)
#
# Installs:
#   - cloudflared (if missing)
#   - SSH configuration
#
# Reads:
#   servers.conf   (alias|host|username|container)
#     - container is OPTIONAL. If set, connecting via that
#       alias will drop straight into that docker container
#       on the remote host (sudo docker exec -it <container> bash)
#       instead of a plain shell.
#
# Author: NexGenAds
# ==========================================================

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------
# Helper functions (must be defined before use)
# ----------------------------------------------------------

function Success($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Info($msg)    { Write-Host "$msg" -ForegroundColor Cyan }
function WarnMsg($msg) { Write-Host "$msg" -ForegroundColor Yellow }
function ErrorMsg($msg){ Write-Host "$msg" -ForegroundColor Red }

# ----------------------------------------------------------
# Paths / variables (must be defined before use)
# ----------------------------------------------------------

$Repo        = "https://raw.githubusercontent.com/nexgenads-ai/server/main"
$TmpDir      = Join-Path $env:TEMP ("nexgenads_" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $TmpDir | Out-Null

$serversFile = Join-Path $TmpDir "servers.conf"
$sshDir      = Join-Path $env:USERPROFILE ".ssh"
$configFile  = Join-Path $sshDir "config"

# Cleanup temp dir on exit
Register-EngineEvent PowerShell.Exiting -Action {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
} | Out-Null

Write-Host ""
Write-Host "=========================================="
Write-Host "      NexGenAds SSH Installer"
Write-Host "=========================================="
Write-Host ""

# ----------------------------------------------------------
# Download server configuration
# ----------------------------------------------------------

Info "Downloading server configuration..."

try {
    Invoke-WebRequest -Uri "$Repo/servers.conf" -OutFile $serversFile -UseBasicParsing
} catch {
    ErrorMsg "Failed to download servers.conf"
    exit 1
}

if (-not (Test-Path $serversFile) -or (Get-Item $serversFile).Length -eq 0) {
    ErrorMsg "Failed to download servers.conf"
    exit 1
}

Success "Downloaded servers.conf"

# ----------------------------------------------------------
# Check SSH Client
# ----------------------------------------------------------

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    ErrorMsg "OpenSSH client is not installed. Install it via: Settings > Apps > Optional Features > OpenSSH Client"
    exit 1
}

Success "OpenSSH found"

# ----------------------------------------------------------
# Install Cloudflared
# ----------------------------------------------------------

if (Get-Command cloudflared -ErrorAction SilentlyContinue) {
    Success "Cloudflared already installed"
} else {
    Info "Installing Cloudflared..."

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        choco install cloudflared -y
    } else {
        ErrorMsg "Neither winget nor choco found. Install cloudflared manually:"
        Write-Host "https://github.com/cloudflare/cloudflared/releases"
        exit 1
    }

    Success "Cloudflared installed"
}

# ----------------------------------------------------------
# Prepare SSH Directory
# ----------------------------------------------------------

if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir | Out-Null
}

if (-not (Test-Path $configFile)) {
    New-Item -ItemType File -Path $configFile | Out-Null
}

$StartMarker = "# >>> NexGenAds SSH START >>>"
$EndMarker   = "# <<< NexGenAds SSH END <<<"

$content = @()
if (Test-Path $configFile) {
    $content = Get-Content $configFile
}

$newContent = @()
$skip = $false

foreach ($line in $content) {
    if ($line -eq $StartMarker) {
        $skip = $true
        continue
    }
    if ($line -eq $EndMarker) {
        $skip = $false
        continue
    }
    if (-not $skip) {
        $newContent += $line
    }
}

$newContent += ""
$newContent += $StartMarker

Get-Content $serversFile | ForEach-Object {
    if ($_ -match "^#" -or $_.Trim() -eq "") {
        return
    }
    $parts     = $_ -split "\|"
    $Alias     = $parts[0]
    $HostName  = $parts[1]
    $UserName  = $parts[2]
    $Container = if ($parts.Count -ge 4) { $parts[3].Trim() } else { "" }

    $newContent += ""
    $newContent += "Host $Alias"
    $newContent += "    HostName $HostName"
    $newContent += "    User $UserName"
    $newContent += "    ProxyCommand cloudflared access ssh --hostname %h"

    if ($Container -ne "") {
        $newContent += "    RequestTTY yes"
        $newContent += "    RemoteCommand sudo docker exec -it $Container bash"
    }
}

$newContent += ""
$newContent += $EndMarker

$newContent | Set-Content $configFile

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------

Write-Host ""
Success "SSH configuration installed."
Write-Host ""
Write-Host "Available hosts:"
Write-Host ""

Get-Content $serversFile | ForEach-Object {
    if ($_ -match "^#" -or $_.Trim() -eq "") { return }
    $parts     = $_ -split "\|"
    $Alias     = $parts[0]
    $Container = if ($parts.Count -ge 4) { $parts[3].Trim() } else { "" }

    if ($Container -ne "") {
        Write-Host "  ssh $Alias   (-> container: $Container)"
    } else {
        Write-Host "  ssh $Alias"
    }
}

Write-Host ""
Success "Installation completed successfully!"
