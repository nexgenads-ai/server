$HostName = "server.nexgenads.space"
$UserName = "home"

Write-Host ""
Write-Host "======================================="
Write-Host " Cloudflare SSH Setup"
Write-Host "======================================="
Write-Host ""

# Check if cloudflared exists
if (!(Get-Command cloudflared -ErrorAction SilentlyContinue)) {

    Write-Host "Installing cloudflared..."

    if (Get-Command winget -ErrorAction SilentlyContinue) {

        winget install Cloudflare.cloudflared `
            --accept-package-agreements `
            --accept-source-agreements

    }
    else {

        Write-Host ""
        Write-Host "Winget is not installed."
        Write-Host "Please install cloudflared manually."
        exit 1

    }

}
else {

    Write-Host "✓ cloudflared already installed."

}

# Verify SSH exists
if (!(Get-Command ssh -ErrorAction SilentlyContinue)) {

    Write-Host ""
    Write-Host "OpenSSH Client is not installed."
    Write-Host "Install the OpenSSH Client feature in Windows."
    exit 1

}

$sshFolder = "$env:USERPROFILE\.ssh"

if (!(Test-Path $sshFolder)) {

    New-Item -ItemType Directory -Path $sshFolder | Out-Null

}

$configFile = "$sshFolder\config"

if (!(Test-Path $configFile)) {

    New-Item -ItemType File -Path $configFile | Out-Null

}

$config = Get-Content $configFile -Raw

if ($config -notmatch [regex]::Escape($HostName)) {

Add-Content $configFile @"

Host $HostName
    HostName $HostName
    User $UserName
    ProxyCommand cloudflared access ssh --hostname %h

"@

    Write-Host "✓ SSH configuration added."

}
else {

    Write-Host "✓ SSH configuration already exists."

}

Write-Host ""
Write-Host "======================================="
Write-Host "Setup Complete!"
Write-Host "======================================="
Write-Host ""
Write-Host "Connect using:"
Write-Host ""
Write-Host "ssh $UserName@$HostName"
Write-Host ""
