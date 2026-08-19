<#
.SYNOPSIS
OpenAstro ASIAIR Plus flash tool (Windows). Run from an elevated PowerShell.

.DESCRIPTION
Just run it:   .\openastro-flash.ps1

You get a menu:
  1) Backup  - save the current eMMC (stock ZWO OS) to a .img.gz + .sha256
  2) Flash   - write the OpenAstro image (downloads the latest release
               automatically if not present; needs 7-Zip to decompress .xz)
  3) Restore - write a saved backup back (return to stock ZWO)

Everything else is automatic: rpiboot is installed on first use, the eMMC is
detected as the disk that newly appears, size-checked (~32 GB), and you
confirm the disk number before anything is written.

ALWAYS make a backup before the first flash - the stock ZWO OS is not
downloadable anywhere; your backup is the only way back.

Scripting: the menu choices also work as subcommands -
  .\openastro-flash.ps1 backup  [-Path out.img.gz]
  .\openastro-flash.ps1 flash   [-Path image.img|.img.gz]
  .\openastro-flash.ps1 restore [-Path backup.img.gz]
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('backup', 'flash', 'restore', 'install-rpiboot')]
    [string]$Command,
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$RepoDir   = Split-Path $PSScriptRoot -Parent
$ImagesDir = Join-Path $RepoDir 'images'
$ReleaseApi = 'https://api.github.com/repos/open-astro/openastro-zwo-asiar-plus-cm4/releases/latest'
$ImageName  = 'openastro-zwo-asiair-plus-cm4.img.xz'

function Log($msg) { Write-Host "[flash] $msg" }
function Fail($msg) { Write-Error "[flash] $msg"; exit 1 }

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'Run this from an elevated (Administrator) PowerShell.'
    }
}

# ------------------------------------------------------------
# rpiboot (installed automatically on first use)
# ------------------------------------------------------------
function Find-Rpiboot {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Raspberry Pi\rpiboot.exe",
        "$env:ProgramFiles\Raspberry Pi\rpiboot.exe"
    ) + (Get-Command rpiboot.exe -ErrorAction SilentlyContinue | ForEach-Object Source)
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Install-Rpiboot {
    if (Find-Rpiboot) { Log "rpiboot already installed: $(Find-Rpiboot)"; return }
    Write-Host ''
    Log "rpiboot (Raspberry Pi usbboot) is needed to talk to the ASIAIR Plus's eMMC."
    if ((Read-Host 'Install it now? [Y/n]') -match '^[nN]') { Fail 'rpiboot is required - aborting.' }
    Log 'Fetching the latest rpiboot installer from raspberrypi/usbboot releases...'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/raspberrypi/usbboot/releases/latest'
    $asset = $rel.assets | Where-Object name -like 'rpiboot_setup*.exe' | Select-Object -First 1
    if (-not $asset) { Fail 'No rpiboot_setup .exe found in the latest release - install manually from https://github.com/raspberrypi/usbboot/releases' }
    $dst = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $dst
    Log "Running installer $($asset.name) (accept the driver install prompts)..."
    Start-Process $dst -Wait
    if (-not (Find-Rpiboot)) { Fail 'rpiboot still not found after install.' }
    Log "rpiboot installed: $(Find-Rpiboot)"
}

# ------------------------------------------------------------
# OpenAstro image (downloaded automatically if missing)
# ------------------------------------------------------------
function Find-XzTool {
    foreach ($c in @(
        (Get-Command xz.exe -ErrorAction SilentlyContinue | ForEach-Object Source),
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Get-OpenAstroImage {
    # Returns the path to a ready-to-write .img (decompressed).
    $img = Join-Path $ImagesDir 'openastro-zwo-asiair-plus-cm4.img'
    if (Test-Path $img) { Log "Using local image: $img"; return $img }

    $xz = Join-Path $ImagesDir $ImageName
    if (-not (Test-Path $xz)) {
        Write-Host ''
        Log 'OpenAstro image not found locally - fetching the latest release...'
        $rel = Invoke-RestMethod $ReleaseApi
        $asset = $rel.assets | Where-Object name -eq $ImageName | Select-Object -First 1
        if (-not $asset) { Fail "could not find $ImageName in the latest GitHub release." }
        New-Item -ItemType Directory -Force $ImagesDir | Out-Null
        Log "Downloading $($asset.browser_download_url) (~550 MB)..."
        Invoke-WebRequest $asset.browser_download_url -OutFile "$xz.part"
        $shaAsset = $rel.assets | Where-Object name -eq "$ImageName.sha256" | Select-Object -First 1
        if ($shaAsset) {
            Invoke-WebRequest $shaAsset.browser_download_url -OutFile "$xz.sha256"
            Log 'Verifying checksum...'
            $want = ((Get-Content "$xz.sha256") -split '\s+')[0].ToLower()
            $got  = (Get-FileHash -Algorithm SHA256 "$xz.part").Hash.ToLower()
            if ($want -ne $got) { Fail "checksum mismatch on downloaded image - delete $xz.part and retry." }
            Log 'Checksum OK.'
        }
        Move-Item "$xz.part" $xz
    }

    $tool = Find-XzTool
    if (-not $tool) {
        Fail "Windows cannot decompress .img.xz natively. Install 7-Zip (https://www.7-zip.org) and re-run - the script will decompress $xz automatically."
    }
    Log "Decompressing $xz (needs ~13 GB free)..."
    if ($tool -like '*7z.exe') {
        & $tool e $xz "-o$ImagesDir" -y | Out-Null
    } else {
        & $tool -dk $xz
    }
    if (-not (Test-Path $img)) { Fail "decompression failed - $img not found." }
    Log "Image ready: $img"
    return $img
}

# ------------------------------------------------------------
# Device discovery
# ------------------------------------------------------------
function Get-EmmcDisk {
    Install-Rpiboot
    $rpiboot = Find-Rpiboot

    $before = (Get-Disk | ForEach-Object Number)

    Write-Host ''
    Write-Host 'Put the ASIAIR Plus in USB device-boot mode now:'
    Write-Host '  1. Make sure the ASIAIR Plus is unplugged (no power).'
    Write-Host '  2. Open the case and short the two nRPIBOOT boot pads on the'
    Write-Host '     carrier board with a jumper wire (keep them shorted).'
    Write-Host '  3. Connect a USB-A (computer) to USB-C (ASIAIR Plus) data cable.'
    Write-Host '  4. Connect 12V DC power - unlike other CM4 boards, the ASIAIR'
    Write-Host '     Plus does NOT power up from the USB cable alone; it needs'
    Write-Host '     12V power connected to turn on.'
    Write-Host ''
    Read-Host 'Press Enter when the pins are shorted and the USB cable is connected' | Out-Null

    # Maybe the gadget is already up from a previous run - skip rpiboot then.
    $disk = Get-Disk | Where-Object FriendlyName -match 'RPi-MSD' | Select-Object -First 1
    if ($disk) {
        Log "RPi mass-storage gadget already present: disk $($disk.Number)"
    } else {
        Log 'Running rpiboot (waits for the CM4)...'
        Start-Process -FilePath $rpiboot -Wait -NoNewWindow
        Log 'Waiting for the eMMC to appear as a USB disk...'
    }
    for ($i = 0; $i -lt 60; $i++) {
        $disk = Get-Disk | Where-Object {
            ($_.Number -notin $before) -or ($_.FriendlyName -match 'RPi-MSD')
        } | Select-Object -First 1
        if ($disk) { break }
        Start-Sleep 1
    }
    if (-not $disk) { Fail 'eMMC never appeared as a disk. Check the USB cable (must be data-capable) and boot mode.' }

    # Sanity: the ASIAIR Plus eMMC is 32 GB (~29 GiB); refuse anything wildly
    # different so a wrong disk can't be nuked.
    $sizeGB = [math]::Round($disk.Size / 1e9)
    Log "Found disk $($disk.Number): $($disk.FriendlyName) ($sizeGB GB)"
    if ($sizeGB -lt 28 -or $sizeGB -gt 36) {
        Fail "Disk $($disk.Number) is $sizeGB GB - not a 32 GB ASIAIR Plus eMMC. Aborting."
    }

    Write-Host ''
    Write-Host "  >>> Target: Disk $($disk.Number) - $($disk.FriendlyName) ($sizeGB GB) <<<" -ForegroundColor Yellow
    Write-Host ''
    $confirm = Read-Host "Type the disk number ($($disk.Number)) to confirm"
    if ($confirm -ne "$($disk.Number)") { Fail 'confirmation mismatch - aborting.' }
    return $disk
}

function Open-RawDisk([int]$Number, [System.IO.FileAccess]$Access) {
    $stream = New-Object System.IO.FileStream(
        "\\.\PhysicalDrive$Number", [System.IO.FileMode]::Open, $Access,
        [System.IO.FileShare]::ReadWrite)
    return $stream
}

# Copies src -> dst with progress; also SHA-256 hashes the bytes as they
# pass through, so a write can be verified afterwards. Returns @{Bytes; Hash}.
function Copy-Stream($src, $dst, [long]$total, [string]$verb) {
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buf = New-Object byte[] (4MB)
    [long]$done = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
    while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
        $dst.Write($buf, 0, $n)
        $hasher.AppendData($buf, 0, $n)
        $done += $n
        if ($sw.ElapsedMilliseconds -gt 2000) {
            if ($total -gt 0) {
                Write-Progress -Activity $verb -Status ("{0:N1} / {1:N1} GB" -f ($done/1e9), ($total/1e9)) -PercentComplete ([math]::Min(100, 100*$done/$total))
            } else {
                Write-Progress -Activity $verb -Status ("{0:N1} GB" -f ($done/1e9))
            }
            $sw.Restart()
        }
    }
    $dst.Flush()
    Write-Progress -Activity $verb -Completed
    return [pscustomobject]@{
        Bytes = $done
        Hash  = ([BitConverter]::ToString($hasher.GetHashAndReset()) -replace '-', '').ToLower()
    }
}

# SHA-256 of the first $Bytes bytes of a physical disk, with progress.
function Get-DiskHash([int]$Number, [long]$Bytes, [string]$verb) {
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $raw = Open-RawDisk $Number ([System.IO.FileAccess]::Read)
    try {
        $buf = New-Object byte[] (4MB)
        [long]$done = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($done -lt $Bytes) {
            $n = $raw.Read($buf, 0, [int][math]::Min($buf.Length, $Bytes - $done))
            if ($n -le 0) { break }
            $hasher.AppendData($buf, 0, $n)
            $done += $n
            if ($sw.ElapsedMilliseconds -gt 2000) {
                Write-Progress -Activity $verb -Status ("{0:N1} / {1:N1} GB" -f ($done/1e9), ($Bytes/1e9)) -PercentComplete ([math]::Min(100, 100*$done/$Bytes))
                $sw.Restart()
            }
        }
        Write-Progress -Activity $verb -Completed
        return ([BitConverter]::ToString($hasher.GetHashAndReset()) -replace '-', '').ToLower()
    } finally { $raw.Dispose() }
}

# ------------------------------------------------------------
# Commands
# ------------------------------------------------------------
function Get-LatestBackup {
    Get-ChildItem -Path $ImagesDir -Filter 'asiair-stock-backup-*.img.gz' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Invoke-Backup([string]$OutPath) {
    if (-not $OutPath) {
        New-Item -ItemType Directory -Force $ImagesDir | Out-Null
        $OutPath = Join-Path $ImagesDir ("asiair-stock-backup-{0:yyyyMMdd}.img.gz" -f (Get-Date))
    }
    if (Test-Path $OutPath) { Fail "$OutPath already exists - refusing to overwrite a backup." }
    $disk = Get-EmmcDisk
    Log "Reading eMMC -> $OutPath (32 GB read, takes a while)..."
    $raw = Open-RawDisk $disk.Number ([System.IO.FileAccess]::Read)
    $out = [System.IO.File]::Create($OutPath)
    $gz  = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionLevel]::Fastest)
    try     { Copy-Stream $raw $gz $disk.Size 'Backing up eMMC' | Out-Null }
    finally { $gz.Dispose(); $out.Dispose(); $raw.Dispose() }
    Log 'Read complete. Computing SHA-256 checksum (takes a few minutes, no output)...'
    $hash = (Get-FileHash -Algorithm SHA256 $OutPath).Hash.ToLower()
    "$hash  $(Split-Path -Leaf $OutPath)" | Set-Content "$OutPath.sha256"
    Log "Backup complete: $OutPath ($([math]::Round((Get-Item $OutPath).Length/1e9, 2)) GB)"
    Log 'Keep this file safe - it is the way back to the stock ZWO OS.'
}

function Invoke-Write([string]$ImagePath, [string]$Label) {
    if (-not (Test-Path $ImagePath)) { Fail "image not found: $ImagePath" }
    if ($ImagePath -like '*.xz') {
        Fail '.img.xz cannot be written directly - install 7-Zip and let the flash option decompress it, or decompress manually first.'
    }
    $disk = Get-EmmcDisk

    Log "Taking disk $($disk.Number) offline for a raw write..."
    Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue | Out-Null
    Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction SilentlyContinue
    Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction SilentlyContinue

    Log "Writing $Label -> Disk $($disk.Number) ..."
    $src = [System.IO.File]::OpenRead($ImagePath)
    if ($ImagePath -like '*.gz') {
        $src = New-Object System.IO.Compression.GZipStream($src, [System.IO.Compression.CompressionMode]::Decompress)
        $total = 0
    } else {
        $total = (Get-Item $ImagePath).Length
    }
    $raw = Open-RawDisk $disk.Number ([System.IO.FileAccess]::Write)
    try     { $res = Copy-Stream $src $raw $total "Writing $Label" }
    finally { $raw.Dispose(); $src.Dispose() }
    Log 'Write complete. Flushing buffers to the eMMC (this can take a minute - the activity LED blinks)...'

    Log ("Verifying: reading back {0:N0} MB from the eMMC and comparing checksums..." -f ($res.Bytes / 1e6))
    $got = Get-DiskHash $disk.Number $res.Bytes "Verifying $Label"
    if ($got -ne $res.Hash) {
        Fail 'VERIFICATION FAILED - the data on the eMMC does not match the image. Do not boot it; re-run the flash (check the USB cable/port).'
    }
    Log 'Verification PASSED - the eMMC matches the image.'

    Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction SilentlyContinue
    Log "$Label written and verified. Disconnect USB, remove the jumper, and power-cycle."
}

function Invoke-Flash([string]$ImagePath) {
    if (-not $ImagePath) { $ImagePath = Get-OpenAstroImage }
    Write-Host ''
    Write-Host 'This OVERWRITES the eMMC with the OpenAstro image.'
    if (-not (Get-LatestBackup)) {
        Write-Host "No stock backup found in $ImagesDir - the stock ZWO OS is NOT"
        Write-Host 'downloadable anywhere; a backup is the only way back to stock.'
        if ((Read-Host 'Make a backup first? [Y/n]') -notmatch '^[nN]') {
            Invoke-Backup $null
            Write-Host ''
            Write-Host 'Backup done - now the flash. Unplug the USB cable, then plug it'
            Write-Host 'back in (keep the jumper shorted) so the board can re-enter boot mode.'
        }
    }
    if ((Read-Host 'Continue with the flash? [y/N]') -notmatch '^[yY]$') { exit 1 }
    Invoke-Write $ImagePath 'OpenAstro image'
}

function Invoke-Restore([string]$ImagePath) {
    if (-not $ImagePath) {
        $b = Get-LatestBackup
        if (-not $b) { Fail "no backup found in $ImagesDir - pass one with -Path" }
        $ImagePath = $b.FullName
    }
    Write-Host ''
    Write-Host 'This OVERWRITES the eMMC with the stock ZWO backup:'
    Write-Host "  $ImagePath"
    if ((Read-Host 'Continue? [y/N]') -notmatch '^[yY]$') { exit 1 }
    Invoke-Write $ImagePath 'stock ZWO backup'
}

function Show-Menu {
    Write-Host ''
    Write-Host 'OpenAstro ASIAIR Plus flash tool'
    Write-Host '==============================='
    Write-Host ''
    Write-Host '  1) Backup  - save the stock ZWO OS from the eMMC (do this first!)'
    Write-Host '  2) Flash   - write the OpenAstro image to the eMMC'
    Write-Host '  3) Restore - write a stock backup back to the eMMC'
    Write-Host '  q) Quit'
    Write-Host ''
    switch (Read-Host 'Choose [1/2/3/q]') {
        '1' { Invoke-Backup $Path }
        '2' { Invoke-Flash $Path }
        '3' { Invoke-Restore $Path }
        'q' { exit 0 }
        default { Fail 'invalid choice' }
    }
}

Assert-Admin
switch ($Command) {
    'install-rpiboot' { Install-Rpiboot }
    'backup'          { Invoke-Backup $Path }
    'flash'           { Invoke-Flash $Path }
    'restore'         { Invoke-Restore $Path }
    default           { Show-Menu }
}
