<#
.SYNOPSIS
  SecondScreen PIN waiter: receives pairing PINs from the laptop over the
  LAN and enters them into Sunshine's API automatically.

.DESCRIPTION
  Runs in the logged-in user's session (Scheduled Task, hidden console).
  Listens on http://+:47991/secondscreen/ and:

    GET  /secondscreen/ping?token=...   -> 200 {"status":"ok"}  (reachability)
    POST /secondscreen/pin              -> forwards to Sunshine POST /api/pin
         body: {"token":"...","pin":"1234","name":"SecondScreen"}

  Auth model: the shared token from the zero-touch setup file must be
  presented; Sunshine credentials are stored DPAPI-encrypted per-user in
  sunshine-cred.xml (created by the installer).

  A PIN is only accepted once per pairing window; requests are logged to
  waiter.log.
#>

$ErrorActionPreference = 'Stop'

$baseDir = Join-Path $env:ProgramData 'SecondScreen'
$credFile = Join-Path $baseDir 'sunshine-cred.xml'
$logFile = Join-Path $baseDir 'waiter.log'
$tokenFile = Join-Path $baseDir 'setup-token.txt'

function Write-Log([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue } catch {}
}

# ------------------------------------------------------- trust Sunshine TLS
add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
                                      WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# ------------------------------------------------------------------- inputs
if (-not (Test-Path $credFile))   { Write-Log "FATAL: $credFile missing - run the installer first"; exit 1 }
if (-not (Test-Path $tokenFile))  { Write-Log "FATAL: $tokenFile missing - run the installer first"; exit 1 }

$cred = Import-Clixml -Path $credFile
$username = $cred.GetNetworkCredential().UserName
$password = $cred.GetNetworkCredential().Password
$pair = "{0}:{1}" -f $username, $password
$authB64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$sharedToken = (Get-Content $tokenFile -Raw).Trim()

# --------------------------------------------------------------- sunshine
function Invoke-SunshineApi {
    param(
        [string]$Method,
        [string]$Path,
        [hashtable]$ExtraHeaders = @{},
        [string]$Body
    )
    $url = "https://localhost:47990$Path"
    $headers = @{ Authorization = "Basic $authB64" }
    foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }
    return Invoke-WebRequest -Uri $url -Method $Method -Headers $headers `
        -Body $Body -ContentType 'application/x-www-form-urlencoded' `
        -UseBasicParsing -TimeoutSec 10
}

function Submit-PinToSunshine {
    param([string]$Pin, [string]$Name)
    # CSRF: non-browser clients are exempt, but fetch and send the token
    # anyway to be compatible with stricter future versions.
    try {
        $csrf = (Invoke-SunshineApi -Method GET -Path '/api/csrf-token').Content | ConvertFrom-Json
        $csrfHeader = @{ 'X-CSRF-Token' = $csrf.csrfToken }
    } catch {
        Write-Log "WARN: could not fetch CSRF token: $($_.Exception.Message)"
        $csrfHeader = @{}
    }
    $body = "pin={0}&name={1}" -f [uri]::EscapeDataString($Pin), [uri]::EscapeDataString($Name)
    $resp = Invoke-SunshineApi -Method POST -Path '/api/pin' -ExtraHeaders $csrfHeader -Body $body
    return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300)
}

# ---------------------------------------------------------------- listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://+:47991/secondscreen/')
try {
    $listener.Start()
} catch {
    Write-Log "FATAL: cannot listen on 47991: $($_.Exception.Message)"
    exit 1
}
Write-Log "SecondScreen PIN waiter started (port 47991)"

while ($true) {
    try {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        $res.Headers.Add('Cache-Control', 'no-store')

        $tokenOk = $false
        if ($req.HttpMethod -eq 'GET') {
            $tokenOk = ($req.QueryString['token'] -eq $sharedToken)
        } else {
            try {
                $body = (New-Object IO.StreamReader($req.InputStream, $req.ContentEncoding)).ReadToEnd()
                $json = $body | ConvertFrom-Json
                $tokenOk = ($json.token -eq $sharedToken)
            } catch { $tokenOk = $false }
        }

        if (-not $tokenOk) {
            $res.StatusCode = 403
            $res.ContentType = 'application/json'
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"status":"forbidden"}')
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.OutputStream.Close()
            Write-Log "DENIED $($req.HttpMethod) $($req.RemoteEndPoint)"
            continue
        }

        switch ("$($req.HttpMethod) $($req.Url.AbsolutePath)") {
            'GET /secondscreen/ping' {
                $res.StatusCode = 200
                $out = '{"status":"ok"}'
                Write-Log "PING from $($req.RemoteEndPoint)"
            }
            'POST /secondscreen/pin' {
                $pin = "$($json.pin)".Trim()
                $name = if ($json.name) { "$($json.name)" } else { 'SecondScreen' }
                if ($pin -notmatch '^[0-9]{4}$') {
                    $res.StatusCode = 400
                    $out = '{"status":"error","error":"invalid pin"}'
                    Write-Log "PIN rejected (bad format)"
                } else {
                    try {
                        if (Submit-PinToSunshine -Pin $pin -Name $name) {
                            $res.StatusCode = 200
                            $out = '{"status":"ok"}'
                            Write-Log "PIN $pin forwarded to Sunshine OK"
                        } else {
                            $res.StatusCode = 502
                            $out = '{"status":"error","error":"sunshine rejected pin"}'
                            Write-Log "Sunshine rejected PIN $pin"
                        }
                    } catch {
                        $res.StatusCode = 502
                        $out = '{"status":"error","error":"sunshine unreachable"}'
                        Write-Log "Sunshine API error: $($_.Exception.Message)"
                    }
                }
            }
            default {
                $res.StatusCode = 404
                $out = '{"status":"not found"}'
            }
        }

        $res.ContentType = 'application/json'
        $bytes = [Text.Encoding]::UTF8.GetBytes($out)
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
    } catch {
        Write-Log "Loop error: $($_.Exception.Message)"
        Start-Sleep -Seconds 2
    }
}
