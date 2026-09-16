#Requires -RunAsAdministrator
<#
.SYNOPSIS
  PC-side setup for SecondScreen: installs Sunshine + Virtual Display
  Driver, sets up automatic pairing (PIN waiter), and can prepare a USB
  stick for ZERO-TOUCH laptop setup (no typing on the laptop at all).

.DESCRIPTION
  Run this ON THE WINDOWS PC that the old laptop will extend.

  Base setup (always):
    1. Sunshine (stream host) + Virtual Display Driver (fake 2nd monitor).
    2. Firewall rules (incl. port 47991 for the pairing helper).
    3. Sunshine credentials captured once (needed by the pairing helper;
       stored DPAPI-encrypted per user).
    4. Scheduled task "SecondScreenPinWaiter" runs the pairing helper at
       every logon (hidden).

  Zero-touch laptop setup (option 1 in the menu, or -PrepareUsbStick):
    5. Ask for Wi-Fi name/password (typed on the PC, not the laptop).
    6. Write secondscreen-setup.txt to the USB stick's data partition.
    7. First boot of the laptop then configures Wi-Fi, pairs with this PC
       automatically, and reboots straight into stream mode.

.USAGE
  Right-click -> Run with PowerShell, or from an admin terminal:
    powershell -ExecutionPolicy Bypass -File .\Install-SecondScreenHost.ps1
    powershell -ExecutionPolicy Bypass -File .\Install-SecondScreenHost.ps1 -PrepareUsbStick
#>

param(
    # Path to a USB stick drive root (e.g. "E:\") to prepare for zero-touch
    # setup. If omitted, an interactive menu is shown after installation.
    [string]$PrepareUsbStick
)

$ErrorActionPreference = 'Stop'

$baseDir = Join-Path $env:ProgramData 'SecondScreen'
$credFile = Join-Path $baseDir 'sunshine-cred.xml'
$tokenFile = Join-Path $baseDir 'setup-token.txt'

function Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Info([string]$msg) { Write-Host "    $msg" -ForegroundColor Gray }
function Ok([string]$msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Warn([string]$msg) { Write-Host "    [!] $msg" -ForegroundColor Yellow }

# =========================================================== base installation
Step "Checking prerequisites"

if (-not $env:SESSIONNAME -or $env:SESSIONNAME -notmatch 'Console') {
    throw "This script must run in a real console session (not over SSH/RDP)."
}
Info "Running on: $env:COMPUTERNAME"

$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
}
Ok "winget found"

# ------------------------------------------------------------- sunshine
Step "Installing Sunshine (stream host)"
$svc = Get-Service -Name Sunshine -ErrorAction SilentlyContinue
if ($svc -or (Get-Command sunshine -ErrorAction SilentlyContinue)) {
    Ok "Sunshine already installed - skipping"
} else {
    winget install --id LizardByte.Sunshine -e --accept-source-agreements --accept-package-agreements
    Ok "Sunshine installed"
}

# ------------------------------------------------------- virtual display
Step "Installing Virtual Display Driver"
$vdd = Get-Package -Name '*Virtual Display Driver*' -ErrorAction SilentlyContinue
if ($vdd) {
    Ok "Virtual Display Driver already installed - skipping"
} else {
    winget install --id VirtualDrivers.Virtual-Display-Driver -e --accept-source-agreements --accept-package-agreements
    Ok "Virtual Display Driver installed"
    Info "A new 'virtual' monitor appears in Windows display settings after reboot."
}

# ------------------------------------------------------------ firewall
Step "Opening firewall for Sunshine + pairing helper"
$rules = @(
    @{ Name = 'Sunshine (HTTP)';    Port = 47990; Proto = 'TCP' },
    @{ Name = 'Sunshine (Web)';     Port = 47989; Proto = 'TCP' },
    @{ Name = 'Sunshine (Video)';   Port = 47998; Proto = 'UDP' },
    @{ Name = 'Sunshine (Control)'; Port = 47999; Proto = 'TCP' },
    @{ Name = 'SecondScreen pairing helper'; Port = 47991; Proto = 'TCP' }
)
foreach ($r in $rules) {
    if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $r.Name `
            -Direction Inbound -Action Allow `
            -Protocol $r.Proto -LocalPort $r.Port | Out-Null
        Ok "Firewall rule added: $($r.Name) ($($r.Proto)/$($r.Port))"
    } else {
        Ok "Firewall rule already present: $($r.Name)"
    }
}

# ------------------------------------------------------------ autostart
Step "Configuring Sunshine to start with Windows"
$svc = Get-Service -Name Sunshine -ErrorAction SilentlyContinue
if ($svc) {
    Set-Service -Name Sunshine -StartupType Automatic
    Start-Service Sunshine -ErrorAction SilentlyContinue
    Ok "Sunshine service set to start automatically"
} else {
    $startFolder = [Environment]::GetFolderPath('Startup')
    $link = Join-Path $startFolder 'Sunshine.lnk'
    if (-not (Test-Path $link)) {
        $sunshineExe = Get-ChildItem "$env:ProgramFiles\Sunshine\sunshine.exe" -ErrorAction SilentlyContinue
        if ($sunshineExe) {
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($link)
            $sc.TargetPath = $sunshineExe.FullName
            $sc.Arguments  = "--portable"
            $sc.Save()
            Ok "Sunshine will launch at login (Startup shortcut)"
        }
    } else {
        Ok "Sunshine Startup shortcut already present"
    }
}

# =================================================== pairing helper (waiter)
Step "Setting up the automatic pairing helper"

# --- Sunshine credentials (needed once to enter PINs into Sunshine's API)
if (Test-Path $credFile) {
    Ok "Sunshine credentials already saved ($credFile)"
} else {
    Info "The pairing helper must log into Sunshine's web API to enter PINs."
    Info "Enter your Sunshine Web UI username + password now."
    Info "(They are stored encrypted (DPAPI) for your user account only.)"
    $cred = Get-Credential -UserName 'sunshine' -Message 'Sunshine Web UI credentials'
    if (-not $cred) { throw "Sunshine credentials are required for automatic pairing." }
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    $cred | Export-Clixml -Path $credFile
    Ok "Credentials saved (encrypted)"
}

# --- shared token (laptop must present it to talk to the helper)
if (Test-Path $tokenFile) {
    $sharedToken = (Get-Content $tokenFile -Raw).Trim()
    Ok "Pairing token already generated"
} else {
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    $sharedToken = [guid]::NewGuid().ToString('N')
    Set-Content -Path $tokenFile -Value $sharedToken -NoNewline
    Ok "Pairing token generated"
}

# --- scheduled task running the waiter at logon (hidden console)
$scriptPath = Join-Path $PSScriptRoot 'Invoke-PinWaiter.ps1'
$runner = Join-Path $baseDir 'waiter-runner.vbs'
New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
Set-Content -Path $runner -Value @"
CreateObject("Wscript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -File ""$scriptPath""", 0, False
"@
$action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$runner`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'SecondScreenPinWaiter' `
    -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'SecondScreenPinWaiter'
Start-Sleep -Seconds 2
Ok "Pairing helper installed and started (task: SecondScreenPinWaiter)"

# ================================================================= helpers
function Get-PcIPv4 {
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notmatch '^169\.' } |
        Sort-Object InterfaceAlias |
        Select-Object -ExpandProperty IPAddress
}

function Show-Qr([string]$text) {
    $mod = Get-Module -ListAvailable QRCodeGenerator
    if (-not $mod) {
        try {
            Info "Installing QRCodeGenerator module (PSGallery)..."
            Install-Module QRCodeGenerator -Scope CurrentUser -Force -AllowClobber
        } catch {
            Warn "Could not install QRCodeGenerator: $($_.Exception.Message)"
            return $false
        }
    }
    try {
        Import-Module QRCodeGenerator
        # Split into chunks: Wi-Fi passwords are not confidential once the
        # stick holds them, but QRs beyond ~1-2 kB get unreliable to scan.
        $max = 800
        $chunkIdx = 0
        while ($chunkIdx * $max -lt $text.Length) {
            $len = [Math]::Min($max, $text.Length - $chunkIdx * $max)
            $chunk = $text.Substring($chunkIdx * $max, $len)
            New-PSOneQRCodeText -Text $chunk -Width 12 -Height 12 -Show
            $chunkIdx++
        }
        return $true
    } catch {
        Warn "QR generation failed: $($_.Exception.Message)"
        return $false
    }
}

function Prepare-UsbStick([string]$driveRoot) {
    if (-not ($driveRoot -match '^[A-Za-z]:\\?$')) {
        throw "'$driveRoot' does not look like a drive root (e.g. E:\)"
    }
    if (-not $driveRoot.EndsWith('\')) { $driveRoot += '\' }

    Step "Preparing USB stick at $driveRoot for zero-touch setup"

    # The stick is read by the laptop's Linux (busybox mount vfat) - FAT32
    # or exFAT are both fine; NTFS would NOT be readable.
    $vol = Get-Volume -DriveLetter ($driveRoot.Substring(0,1)) -ErrorAction SilentlyContinue
    if ($vol) {
        Info "Volume: $($vol.FriendlyName) (filesystem: $($vol.FileSystem), label: $($vol.FileSystemLabel))"
        if ($vol.FileSystem -eq 'NTFS') {
            throw "The stick is NTFS. Reformat it as FAT32/exFAT first (right-click -> Format)."
        }
    }

    # --- Wi-Fi credentials (typed once, here on the PC)
    $wifi = Get-Credential -UserName 'wifi' -Message 'Wi-Fi name (as username) and password (as password)'
    if (-not $wifi) { throw "Wi-Fi credentials are required." }
    $ssid = $wifi.GetNetworkCredential().UserName
    $psk  = $wifi.GetNetworkCredential().Password
    if (-not $ssid -or -not $psk) { throw "Both Wi-Fi name and password are required." }

    $hidden = Read-Host "Is the network hidden? [y/N]"
    $hidden = if ($hidden -match '^[yY]') { 'y' } else { 'n' }

    # --- PC address (first non-loopback IPv4; adjustable)
    $ips = @(Get-PcIPv4)
    if ($ips.Count -eq 0) { throw "No IPv4 address found - is this PC online?" }
    $defaultIp = $ips[0]
    if ($ips.Count -gt 1) {
        Info "Multiple network interfaces found:"
        for ($i = 0; $i -lt $ips.Count; $i++) { Info "  [$($i+1)] $($ips[$i])" }
        $sel = Read-Host "Which IP should the laptop connect to? [1]"
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $ips.Count) {
            $defaultIp = $ips[[int]$sel - 1]
        }
    }

    # --- write the setup file the laptop's wizard consumes
    $setupFile = Join-Path $driveRoot 'secondscreen-setup.txt'
    $config = @(
        'secondscreen-zero-touch-v1'
        "ssid=$ssid"
        "psk=$psk"
        "hidden=$hidden"
        "host=$defaultIp"
        "token=$sharedToken"
        'resolution=1920x1080'
        'fps=60'
        'bitrate=8000'
        'app=Desktop'
    ) -join "`r`n"
    Set-Content -Path $setupFile -Value $config -Encoding ASCII -NoNewline
    Ok "Wrote $setupFile"

    # --- summary + optional QR
    Write-Host ""
    Write-Host "  Zero-touch setup is READY." -ForegroundColor Green
    Write-Host "  Plug the stick into the laptop, boot it from USB - that's it." -ForegroundColor Green
    Write-Host ""
    Info "The Wi-Fi password is stored PLAINTEXT on this stick. Keep the stick safe."
    Write-Host ""
    $qr = Read-Host "Show the config as a QR code too? [y/N]"
    if ($qr -match '^[yY]') {
        if (-not (Show-Qr $config)) {
            Write-Host $config -ForegroundColor DarkGray
            Info "(Copy the text above into any 'text to QR' website as a fallback.)"
        }
    }
}

# =================================================================== menu
if ($PrepareUsbStick) {
    Prepare-UsbStick -DriveRoot $PrepareUsbStick
} else {
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor Green
    Write-Host " PC setup complete!" -ForegroundColor Green
    Write-Host "===========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Sunshine Web UI : https://localhost:47990"
    Write-Host "  This PC's IP    : $((Get-PcIPv4) -join ', ')"
    Write-Host ""
    Write-Host " What now?"
    Write-Host "  [1] Prepare a USB stick for ZERO-TOUCH laptop setup (recommended)"
    Write-Host "  [2] Skip - configure the laptop interactively at its first boot"
    $choice = Read-Host " Choice"
    if ($choice -eq '1') {
        $drive = Read-Host " USB stick drive letter (e.g. E)"
        Prepare-UsbStick -DriveRoot "$drive`:"
    } else {
        Write-Host ""
        Write-Host " Next steps:"
        Write-Host "  1. Flash the SecondScreen image to a USB stick (Etcher/Rufus, DD mode)."
        Write-Host "  2. Boot the laptop from it - the on-screen wizard asks for Wi-Fi,"
        Write-Host "     PC address ($((Get-PcIPv4) -join ', ')) and shows a PIN to enter at"
        Write-Host "     https://localhost:47990 -> 'PIN'."
    }
}

Write-Host ""
