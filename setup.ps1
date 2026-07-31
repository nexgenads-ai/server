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

    $parts = $_ -split "\|"

    $Alias = $parts[0]
    $HostName = $parts[1]
    $UserName = $parts[2]

    $newContent += ""
    $newContent += "Host $Alias"
    $newContent += "    HostName $HostName"
    $newContent += "    User $UserName"
    $newContent += "    ProxyCommand cloudflared access ssh --hostname %h"

}

$newContent += ""
$newContent += $EndMarker

$newContent | Set-Content $configFile
