param(
  [switch]$SkipNodeInstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { $PSDefaultParameterValues['Invoke-WebRequest:UseBasicParsing'] = $true } catch {}

$NpmExe = "npm.cmd"
$VercelExe = "vercel.cmd"
$script:LastVercelAuthStatus = "unknown"

try {
  [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {}

function Write-Banner {
  Clear-Host
  Write-Host "==============================================" -ForegroundColor Cyan
  Write-Host " XHTTPRelayECO Windows Installer by @b3hnamrjd" -ForegroundColor Cyan
  Write-Host " Telegram Channel : https://t.me/B3hnamR" -ForegroundColor Cyan
  Write-Host " GitHub : https://github.com/B3hnamR/XHTTPRelayECO" -ForegroundColor Cyan
  Write-Host "==============================================" -ForegroundColor Cyan
  Write-Host ""
}

function Write-PreflightNotice {
  Write-Host "Important: connect your VPN in TUN Mode or set as `"System Proxy`" before continuing." -ForegroundColor Magenta
  Write-Host "Tip: Press Ctrl+C at any step to stop/exit." -ForegroundColor DarkYellow
}

function Write-Step([string]$Text) {
  Write-Host ""
  Write-Host ">> $Text" -ForegroundColor Yellow
}

function Read-Default([string]$Prompt, [string]$DefaultValue) {
  $raw = Read-Host "$Prompt [$DefaultValue]"
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  return $raw.Trim()
}

function Read-Optional([string]$Prompt) {
  $raw = Read-Host $Prompt
  if ([string]::IsNullOrWhiteSpace($raw)) { return "" }
  return $raw.Trim()
}

function Read-Required([string]$Prompt) {
  while ($true) {
    $raw = Read-Host $Prompt
    if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw.Trim() }
    Write-Host "Value is required." -ForegroundColor Red
  }
}

function Normalize-PathLike([string]$PathValue) {
  $p = ""
  if ($null -ne $PathValue) { $p = $PathValue.Trim() }
  if ([string]::IsNullOrWhiteSpace($p)) { return "" }
  if (-not $p.StartsWith("/")) { $p = "/$p" }
  return $p
}

function Read-YesNo([string]$Prompt, [bool]$DefaultYes = $true) {
  $def = if ($DefaultYes) { "Y/n" } else { "y/N" }
  while ($true) {
    $v = Read-Host "$Prompt ($def)"
    if ([string]::IsNullOrWhiteSpace($v)) { return $DefaultYes }
    $x = $v.Trim().ToLowerInvariant()
    if ($x -eq "y" -or $x -eq "yes") { return $true }
    if ($x -eq "n" -or $x -eq "no") { return $false }
    Write-Host "Please enter y or n." -ForegroundColor DarkYellow
  }
}

function Choose-DeploymentMode {
  Write-Host ""
  Write-Host "Choose deployment mode:" -ForegroundColor Cyan
  Write-Host "[1] ECO_MIN_COST             | Node + Fluid OFF | cheapest stable profile"
  Write-Host "    MAX_INFLIGHT=128 | MAX_UP_BPS=2621440 | MAX_DOWN_BPS=2621440 | UPSTREAM_TIMEOUT_MS=50000"
  Write-Host "[2] BALANCED_LOW_TIMEOUT     | Node + Fluid ON  | better latency with moderate cost"
  Write-Host "    MAX_INFLIGHT=256 | MAX_UP_BPS=5242880 | MAX_DOWN_BPS=5242880 | UPSTREAM_TIMEOUT_MS=60000"
  Write-Host "[3] MAX_STABILITY_HIGH_CONN  | Node + Fluid ON  | high connection capacity"
  Write-Host "    MAX_INFLIGHT=512 | MAX_UP_BPS=10485760 | MAX_DOWN_BPS=10485760 | UPSTREAM_TIMEOUT_MS=60000"
  Write-Host "[4] STRESS_TEST              | Node + Fluid ON  | aggressive profile for testing only"
  Write-Host "    MAX_INFLIGHT=896 | MAX_UP_BPS=26214400 | MAX_DOWN_BPS=26214400 | UPSTREAM_TIMEOUT_MS=60000"
  Write-Host "[5] FAST_PIPE_REWRITE_SECURE | Rewrite (optional x-relay-key lock)"
  Write-Host "[6] CUSTOM_BUILD             | manually set everything"

  $choice = Read-Default "Select mode" "2"
  switch ($choice) {
    "1" {
      return @{
        ModeKey = "ECO_MIN_COST"
        Runtime = "node"
        FluidEnabled = $false
        MaxInflight = "128"
        MaxUpBps = "2621440"
        MaxDownBps = "2621440"
        UpstreamTimeoutMs = "50000"
        FunctionTimeoutSec = 120
        RunStressAfterDeploy = $false
        RequireRelayKey = $false
      }
    }
    "2" {
      return @{
        ModeKey = "BALANCED_LOW_TIMEOUT"
        Runtime = "node"
        FluidEnabled = $true
        MaxInflight = "256"
        MaxUpBps = "5242880"
        MaxDownBps = "5242880"
        UpstreamTimeoutMs = "60000"
        FunctionTimeoutSec = 180
        RunStressAfterDeploy = $false
        RequireRelayKey = $false
      }
    }
    "3" {
      return @{
        ModeKey = "MAX_STABILITY_HIGH_CONN"
        Runtime = "node"
        FluidEnabled = $true
        MaxInflight = "512"
        MaxUpBps = "10485760"
        MaxDownBps = "10485760"
        UpstreamTimeoutMs = "60000"
        FunctionTimeoutSec = 240
        RunStressAfterDeploy = $false
        RequireRelayKey = $false
      }
    }
    "4" {
      return @{
        ModeKey = "STRESS_TEST"
        Runtime = "node"
        FluidEnabled = $true
        MaxInflight = "896"
        MaxUpBps = "26214400"
        MaxDownBps = "26214400"
        UpstreamTimeoutMs = "60000"
        FunctionTimeoutSec = 300
        RunStressAfterDeploy = $true
        RequireRelayKey = $false
      }
    }
    "5" {
      return @{
        ModeKey = "FAST_PIPE_REWRITE_SECURE"
        Runtime = "rewrite"
        FluidEnabled = $false
        MaxInflight = ""
        MaxUpBps = ""
        MaxDownBps = ""
        UpstreamTimeoutMs = "30000"
        FunctionTimeoutSec = 0
        RunStressAfterDeploy = $false
        RequireRelayKey = $false
      }
    }
    "6" {
      $runtimePick = Read-Default "Runtime type (node/rewrite)" "node"
      $runtimeType = if ($runtimePick.Trim().ToLowerInvariant() -eq "rewrite") { "rewrite" } else { "node" }
      $fluidEnabled = $false
      $maxInflight = ""
      $maxUpBps = ""
      $maxDownBps = ""
      $fnTimeout = 180
      if ($runtimeType -eq "node") {
        $fluidEnabled = Read-YesNo -Prompt "Enable Fluid Compute for this build" -DefaultYes $true
        $maxInflight = Read-Required "MAX_INFLIGHT (example: 256)"
        $maxUpBps = Read-Required "MAX_UP_BPS (bytes/sec, example: 5242880)"
        $maxDownBps = Read-Required "MAX_DOWN_BPS (bytes/sec, example: 5242880)"
        $fnTimeout = [int](Read-Default "Function timeout seconds (30..800)" "180")
      }
      return @{
        ModeKey = "CUSTOM_BUILD"
        Runtime = $runtimeType
        FluidEnabled = $fluidEnabled
        MaxInflight = $maxInflight
        MaxUpBps = $maxUpBps
        MaxDownBps = $maxDownBps
        UpstreamTimeoutMs = (Read-Default "UPSTREAM_TIMEOUT_MS (ms)" "50000")
        FunctionTimeoutSec = $fnTimeout
        RunStressAfterDeploy = $false
        RequireRelayKey = $false
      }
    }
    default {
      return @{
        ModeKey = "BALANCED_LOW_TIMEOUT"
        Runtime = "node"
        FluidEnabled = $true
        MaxInflight = "256"
        MaxUpBps = "5242880"
        MaxDownBps = "5242880"
        UpstreamTimeoutMs = "60000"
        FunctionTimeoutSec = 180
        RunStressAfterDeploy = $false
        RequireRelayKey = $false
      }
    }
  }
}

function Get-UpstreamHostFromDomain([string]$TargetDomain) {
  if ([string]::IsNullOrWhiteSpace($TargetDomain)) { return "" }
  $raw = $TargetDomain.Trim()
  try {
    $u = [uri]$raw
    if ($null -ne $u -and -not [string]::IsNullOrWhiteSpace($u.Host)) { return $u.Host }
  } catch {}
  # Fallback: user may enter domain:port without scheme.
  try {
    if (-not ($raw -match '^[a-zA-Z][a-zA-Z0-9+\-.]*://')) {
      $u2 = [uri]("https://$raw")
      if ($null -ne $u2 -and -not [string]::IsNullOrWhiteSpace($u2.Host)) { return $u2.Host }
    }
  } catch {}
  return ""
}

function Get-UpstreamIpv4Candidates([string]$HostName) {
  $result = [ordered]@{
    Local  = @()
    Public = @()
    All    = @()
  }
  if ([string]::IsNullOrWhiteSpace($HostName)) { return $result }

  $local = New-Object System.Collections.Generic.List[string]
  $public = New-Object System.Collections.Generic.List[string]
  $all = New-Object System.Collections.Generic.List[string]

  $addUnique = {
    param([System.Collections.Generic.List[string]]$list, [string]$value)
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    $v = $value.Trim()
    if (-not $list.Contains($v)) { [void]$list.Add($v) }
  }

  try {
    $ips = [System.Net.Dns]::GetHostAddresses($HostName)
    foreach ($ip in $ips) {
      if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $s = [string]$ip.IPAddressToString
        & $addUnique $local $s
        & $addUnique $all $s
      }
    }
  } catch {}

  $dnsServers = @("1.1.1.1", "8.8.8.8", "9.9.9.9")
  foreach ($dns in $dnsServers) {
    try {
      $records = Resolve-DnsName -Name $HostName -Type A -Server $dns -ErrorAction Stop
      foreach ($r in $records) {
        if ($null -ne $r.IPAddress -and -not [string]::IsNullOrWhiteSpace([string]$r.IPAddress)) {
          $s = [string]$r.IPAddress
          & $addUnique $public $s
          & $addUnique $all $s
        }
      }
    } catch {}
  }

  $result.Local = @($local.ToArray())
  $result.Public = @($public.ToArray())
  $result.All = @($all.ToArray())
  return $result
}

function Suggest-RegionFromCountry([string]$CountryName) {
  if ([string]::IsNullOrWhiteSpace($CountryName)) { return "iad1" }
  $c = $CountryName.ToLowerInvariant()
  if ($c -match "germany|france|netherlands|belgium|sweden|poland|switzerland|austria|europe") { return "fra1" }
  if ($c -match "united kingdom|ireland") { return "lhr1" }
  if ($c -match "india|pakistan|uae|turkey|iran|qatar|saudi") { return "fra1" }
  if ($c -match "japan|singapore|korea|hong kong") { return "hnd1" }
  return "iad1"
}

function Try-ResolveCountryFromIp([string]$IpAddress) {
  if ([string]::IsNullOrWhiteSpace($IpAddress)) { return "" }
  try {
    $url = "https://ipwho.is/$IpAddress"
    $resp = Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 6
    if ($null -ne $resp -and $resp.success -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$resp.country)) {
      return [string]$resp.country
    }
  } catch {}
  return ""
}

function Choose-FunctionRegion([string]$TargetDomain) {
  $defaultRegion = "iad1"
  $upHost = Get-UpstreamHostFromDomain -TargetDomain $TargetDomain
  if (-not [string]::IsNullOrWhiteSpace($upHost)) {
    $resolved = Get-UpstreamIpv4Candidates -HostName $upHost
    $localIps = @()
    $publicIps = @()
    $allIps = @()
    if ($null -ne $resolved.Local) { $localIps = @($resolved.Local) }
    if ($null -ne $resolved.Public) { $publicIps = @($resolved.Public) }
    if ($null -ne $resolved.All) { $allIps = @($resolved.All) }

    $hintIp = ""
    if ($publicIps.Count -gt 0) { $hintIp = [string]$publicIps[0] }
    elseif ($allIps.Count -gt 0) { $hintIp = [string]$allIps[0] }

    if ($allIps.Count -gt 0) {
      Write-Host ("Auto hint: DNS A records for '{0}' => {1}" -f $upHost, ($allIps -join ", ")) -ForegroundColor DarkGray
    }
    if ($localIps.Count -gt 0 -and $publicIps.Count -gt 0 -and ([string]$localIps[0] -ne [string]$publicIps[0])) {
      Write-Host ("Auto hint warning: local DNS resolves to {0} but public resolver resolves to {1}. Region suggestion will use public DNS." -f $localIps[0], $publicIps[0]) -ForegroundColor Yellow
    }

    $country = Try-ResolveCountryFromIp -IpAddress $hintIp
    if (-not [string]::IsNullOrWhiteSpace($country)) {
      $defaultRegion = Suggest-RegionFromCountry -CountryName $country
      Write-Host ("Auto hint: using IP {0} ({1}) -> suggested region '{2}'." -f $hintIp, $country, $defaultRegion) -ForegroundColor DarkCyan
    } elseif (-not [string]::IsNullOrWhiteSpace($hintIp)) {
      Write-Host ("Auto hint fallback: host '{0}' -> {1}, but country lookup failed (ipwho.is blocked/timeout). Using '{2}'." -f $upHost, $hintIp, $defaultRegion) -ForegroundColor DarkGray
    } else {
      Write-Host ("Auto hint fallback: DNS lookup failed for host '{0}'. Using '{1}'." -f $upHost, $defaultRegion) -ForegroundColor DarkGray
    }
  } else {
    Write-Host ("Auto hint fallback: could not parse host from TARGET_DOMAIN ('{0}'). Use full format like https://domain:port. Using '{1}'." -f $TargetDomain, $defaultRegion) -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "Choose Vercel function region (you can change later):" -ForegroundColor Cyan
  Write-Host "[1] iad1 (Washington, US) - default global fallback"
  Write-Host "[2] fra1 (Frankfurt, DE) - good for Europe/Middle East routes"
  Write-Host "[3] lhr1 (London, UK)"
  Write-Host "[4] hnd1 (Tokyo, JP)"
  Write-Host "[5] Custom region code"
  $pick = Read-Default ("Select region (suggested: {0})" -f $defaultRegion) "1"
  switch ($pick) {
    "2" { return "fra1" }
    "3" { return "lhr1" }
    "4" { return "hnd1" }
    "5" { return (Read-Required "Custom region code (example: fra1)").ToLowerInvariant() }
    default { return $defaultRegion }
  }
}

function Refresh-Path {
  $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $user = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machine;$user"
}

function Get-TokenStorePath([string]$ProjectRoot) {
  return (Join-Path $ProjectRoot ".vercel-token.dpapi")
}

function Get-ScopeStorePath([string]$ProjectRoot) {
  return (Join-Path $ProjectRoot ".vercel-scope.txt")
}

function Save-Scope([string]$Scope, [string]$Path) {
  $value = ""
  if ($null -ne $Scope) { $value = $Scope.Trim() }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $value, $utf8NoBom)
}

function Load-Scope([string]$Path) {
  if (-not (Test-Path $Path)) { return "" }
  try {
    $raw = Get-Content $Path -Raw
    if ($null -eq $raw) { return "" }
    return $raw.Trim()
  } catch {
    return ""
  }
}

function Get-VercelTeamSlugs {
  $result = Invoke-NativeSafe -FilePath $VercelExe -Arguments @("teams", "ls", "--no-color")
  if ($result.ExitCode -ne 0) { return @() }
  $slugs = @()
  foreach ($line in $result.Output) {
    $trim = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trim)) { continue }
    if ($trim -match '^(Fetching|ID|Name|Slug|Teams|Visit|Error:|Warning:)') { continue }
    if ($trim.StartsWith(">")) { continue }
    $parts = $trim -split '\s+'
    if ($parts.Count -ge 1) {
      $candidate = $parts[0]
      if ($candidate -match '^[a-zA-Z0-9][a-zA-Z0-9\-_]+$') {
        $slugs += $candidate
      }
    }
  }
  return @($slugs | Sort-Object -Unique)
}

function Normalize-ScopeForCli([string]$Scope) {
  if ([string]::IsNullOrWhiteSpace($Scope)) { return "" }
  $s = $Scope.Trim()
  # Vercel CLI scope expects team slug, not orgId like team_xxx.
  if ($s.StartsWith("team_")) { return "" }
  return $s
}

function Validate-Scope([string]$Scope) {
  $s = Normalize-ScopeForCli -Scope $Scope
  if ([string]::IsNullOrWhiteSpace($s)) { return $true }
  $slugs = Get-VercelTeamSlugs
  if ($slugs.Count -eq 0) { return $true }
  return ($slugs -contains $s)
}

function Save-TokenSecure([string]$Token, [string]$Path) {
  $secure = ConvertTo-SecureString -String $Token -AsPlainText -Force
  $text = ConvertFrom-SecureString -SecureString $secure
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $text, $utf8NoBom)
}

function Load-TokenSecure([string]$Path) {
  if (-not (Test-Path $Path)) { return "" }
  try {
    $text = (Get-Content $Path -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $secure = ConvertTo-SecureString -String $text
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
      return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  } catch {
    return ""
  }
}

function Invoke-NativeSafe {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.WorkingDirectory = (Get-Location).Path
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  # PowerShell 5.1-compatible argument handling
  $escaped = $Arguments | ForEach-Object {
    if ($_ -match '[\s"]') {
      '"' + ($_ -replace '"', '\"') + '"'
    } else {
      $_
    }
  }
  $psi.Arguments = ($escaped -join ' ')

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()

  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  $lines = @()
  if (-not [string]::IsNullOrWhiteSpace($stdout)) {
    $lines += ($stdout -split "`r?`n" | Where-Object { $_ -ne "" })
  }
  if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    $lines += ($stderr -split "`r?`n" | Where-Object { $_ -ne "" })
  }

  return @{
    Output = @($lines)
    ExitCode = $proc.ExitCode
  }
}

function Get-VercelTokenArgs {
  if (-not [string]::IsNullOrWhiteSpace($env:VERCEL_TOKEN)) {
    return @("--token", $env:VERCEL_TOKEN)
  }
  return @()
}

function New-RandomProjectName {
  $chars = "abcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
  $suffix = -join (1..8 | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
  return "relay-$suffix"
}

function Ensure-NodeAndNpm {
  if (Get-Command $NpmExe -ErrorAction SilentlyContinue) {
    Write-Host "npm already installed." -ForegroundColor Green
    return
  }

  if ($SkipNodeInstall) {
    throw "npm is missing and -SkipNodeInstall was used."
  }

  if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
    throw "winget not found. Install Node.js LTS manually and run again."
  }

  Write-Step "Installing Node.js LTS (npm included) via winget..."
  winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
  Refresh-Path

  if (-not (Get-Command $NpmExe -ErrorAction SilentlyContinue)) {
    throw "Node.js installation finished but npm is still not detected. Re-open PowerShell and retry."
  }
}

function Ensure-VercelCli {
  if (Get-Command $VercelExe -ErrorAction SilentlyContinue) {
    Write-Host "Vercel CLI already installed." -ForegroundColor Green
    return
  }

  Write-Step "Installing Vercel CLI..."
  & $NpmExe i -g vercel | Out-Host
  Refresh-Path
  if (-not (Get-Command $VercelExe -ErrorAction SilentlyContinue)) {
    throw "vercel command not found after installation."
  }
}

function Start-VercelOobLogin([string]$OutputDir) {
  Write-Host "Starting manual device login (no auto browser)..." -ForegroundColor Yellow
  $prevBrowser = $env:BROWSER
  $env:BROWSER = "none"
  try {
    $loginResult = Invoke-NativeSafe -FilePath $VercelExe -Arguments @("login", "--oob", "--no-color")
  } finally {
    if ($null -eq $prevBrowser) {
      Remove-Item Env:\BROWSER -ErrorAction SilentlyContinue
    } else {
      $env:BROWSER = $prevBrowser
    }
  }
  $loginResult.Output | Out-Host
  if ($loginResult.ExitCode -ne 0) {
    throw "vercel login failed."
  }

  $urls = @()
  foreach ($line in $loginResult.Output) {
    $matches = [regex]::Matches($line, 'https?://[^\s\)\]]+')
    foreach ($m in $matches) {
      if ($m.Value -match 'vercel\.com/(oauth/device|device)') {
        $urls += $m.Value
      }
    }
  }
  $urls = $urls | Select-Object -Unique

  if ($urls.Count -gt 0) {
    $txtPath = Join-Path $OutputDir "vercel-login-link.txt"
    $content = @(
      "Vercel Login Links"
      "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
      ""
    ) + $urls
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($txtPath, $content, $utf8NoBom)

    Write-Host ""
    Write-Host "Manual login URL(s):" -ForegroundColor Cyan
    $urls | ForEach-Object { Write-Host "  $_" -ForegroundColor Cyan }
    Write-Host "Saved to: $txtPath" -ForegroundColor Cyan
  } else {
    Write-Host "No explicit login URL found in output. If prompted, use: https://vercel.com/device" -ForegroundColor DarkYellow
  }
}

function Ensure-VercelLogin([string]$OutputDir, [string]$TokenStorePath) {
  Write-Step "Checking Vercel login..."

  Write-Host "Choose auth mode:" -ForegroundColor Cyan
  Write-Host "[1] Use existing login session (default)"
  Write-Host "[2] Token mode (recommended: never opens browser, supports secure save)"
  $authMode = Read-Default "Select auth mode" "1"

  if ($authMode -eq "2" -or $authMode -eq "3") {
    $token = ""
    $saved = Load-TokenSecure -Path $TokenStorePath
    if (-not [string]::IsNullOrWhiteSpace($saved)) {
      $useSaved = Read-Default "Use saved encrypted token from project folder? (Y/n)" "y"
      if ($useSaved.ToLowerInvariant() -ne "n") {
        $token = $saved
        Write-Host "Using saved encrypted token." -ForegroundColor Green
      }
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
      $token = Read-Required "Paste Vercel token (create from Vercel dashboard -> Settings -> Tokens)"
      $saveNow = Read-Default "Save token encrypted in this project folder? (Y/n)" "y"
      if ($saveNow.ToLowerInvariant() -ne "n") {
        Save-TokenSecure -Token $token -Path $TokenStorePath
        Write-Host "Token saved securely: $TokenStorePath" -ForegroundColor Green
      }
    }

    # Normalize token input: avoid hidden spaces/newlines/quotes from copy-paste
    $token = ([string]$token).Trim().Trim('"').Trim("'")
    $env:VERCEL_TOKEN = $token

    # Auth check strategy (robust):
    # 1) API direct check (most reliable)
    # 2) CLI whoami --token
    # 3) CLI whoami (uses VERCEL_TOKEN from env)
    $apiOk = $false
    $apiErr = ""
    try {
      $apiUser = Invoke-RestMethod -Method Get -Uri "https://api.vercel.com/v2/user" -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 15
      if ($null -ne $apiUser -and $null -ne $apiUser.user -and -not [string]::IsNullOrWhiteSpace([string]$apiUser.user.id)) {
        $apiOk = $true
      }
    } catch {
      $apiErr = $_.Exception.Message
    }

    $tokenWhoami = Invoke-NativeSafe -FilePath $VercelExe -Arguments @("whoami", "--token", $token)
    $envWhoami = Invoke-NativeSafe -FilePath $VercelExe -Arguments @("whoami")

    $cliOk = ($tokenWhoami.ExitCode -eq 0 -or $envWhoami.ExitCode -eq 0)
    if (-not $apiOk -and -not $cliOk) {
      Write-Host "Token auth failed." -ForegroundColor Red
      $raw = (($tokenWhoami.Output + $envWhoami.Output) | Out-String).Trim()
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "Vercel response (short):" -ForegroundColor DarkYellow
        $raw.Split("`n") | Select-Object -First 5 | ForEach-Object { Write-Host (" - {0}" -f ($_.Trim())) -ForegroundColor DarkYellow }
      }
      if (-not [string]::IsNullOrWhiteSpace($apiErr)) {
        Write-Host ("API response (short): {0}" -f $apiErr) -ForegroundColor DarkYellow
      }
      Write-Host ""
      Write-Host "How to fix:" -ForegroundColor Cyan
      Write-Host " 1) Create a NEW Full Access token in Vercel Dashboard > Settings > Tokens"
      Write-Host " 2) Paste token again carefully (no extra space/newline)"
      Write-Host " 3) If team project: ensure correct scope/team slug"
      throw "Token auth failed. Please create a new token and retry."
    }
    if ($apiOk -and $tokenWhoami.ExitCode -ne 0 -and $envWhoami.ExitCode -ne 0) {
      Write-Host "Token validated by API. Continuing (CLI whoami check skipped)." -ForegroundColor Green
    } elseif ($tokenWhoami.ExitCode -eq 0) {
      $tokenWhoami.Output | Out-Host
    } elseif ($envWhoami.ExitCode -eq 0) {
      $envWhoami.Output | Out-Host
    } else {
      Write-Host "Token validated." -ForegroundColor Green
    }
    return
  }

  $whoamiResult = Invoke-NativeSafe -FilePath $VercelExe -Arguments @("whoami")
  $loggedIn = $whoamiResult.ExitCode -eq 0

  if ($authMode -eq "1" -and $loggedIn) {
    $whoamiResult.Output | Out-Host
    $useCurrent = Read-Default "Use current logged-in session? (Y/n)" "y"
    if ($useCurrent.ToLowerInvariant() -eq "n") {
      Write-Step "Logging out and creating a fresh login link..."
      $logoutResult = Invoke-NativeSafe -FilePath $VercelExe -Arguments @("logout")
      $logoutResult.Output | Out-Host
      Start-VercelOobLogin -OutputDir $OutputDir
    }
  } else {
    Start-VercelOobLogin -OutputDir $OutputDir
  }

  & $VercelExe whoami | Out-Host
}

function Resolve-SessionScope([string]$ScopeStorePath) {
  $savedScope = Normalize-ScopeForCli -Scope (Load-Scope -Path $ScopeStorePath)
  if (-not [string]::IsNullOrWhiteSpace($savedScope)) {
    if (-not (Validate-Scope -Scope $savedScope)) {
      Write-Host "Saved scope '$savedScope' is invalid and will be ignored." -ForegroundColor Red
      Save-Scope -Scope "" -Path $ScopeStorePath
      $savedScope = ""
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($savedScope)) {
    $useSaved = Read-Default ("Use saved scope/team '{0}'? (Y/n)" -f $savedScope) "y"
    if ($useSaved.ToLowerInvariant() -ne "n") {
      return $savedScope
    }
  }

  Write-Host ""
  Write-Host "Scope note: enter your Vercel team slug to avoid wrong CLI context." -ForegroundColor DarkYellow
  $teams = Get-VercelTeamSlugs
  if ($teams.Count -gt 0) {
    Write-Host "Detected team slugs: $($teams -join ', ')" -ForegroundColor Cyan
  }
  while ($true) {
    $scopeInput = Read-Optional "Scope slug/team (optional, press Enter for personal account)"
    $scope = Normalize-ScopeForCli -Scope $scopeInput
    if ([string]::IsNullOrWhiteSpace($scope)) {
      Save-Scope -Scope "" -Path $ScopeStorePath
      return ""
    }
    if (Validate-Scope -Scope $scope) {
      Save-Scope -Scope $scope -Path $ScopeStorePath
      return $scope
    }
    Write-Host "Scope '$scope' does not exist. Enter a valid team slug or press Enter for personal account." -ForegroundColor Red
  }
}

function Ensure-VercelProject([string]$ProjectName, [string]$Scope) {
  Write-Step "Creating project (or reusing if already exists)..."
  $Scope = Normalize-ScopeForCli -Scope $Scope
  $args = @("project", "add", $ProjectName)
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  $args += (Get-VercelTokenArgs)

  $result = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
  $output = $result.Output
  $text = $output | Out-String
  if ($result.ExitCode -ne 0 -and ($text -notmatch "already exists")) {
    if (-not [string]::IsNullOrWhiteSpace($Scope) -and $text -match "(?i)(scope does not exist|specified scope does not exist|invalid scope|scope-not-existent)") {
      Write-Host "Scope '$Scope' is invalid/unavailable. Retrying with personal account context..." -ForegroundColor DarkYellow
      $retry = Invoke-NativeSafe -FilePath $VercelExe -Arguments (@("project", "add", $ProjectName) + (Get-VercelTokenArgs))
      $retry.Output | Out-Host
      if ($retry.ExitCode -eq 0 -or (($retry.Output | Out-String) -match "already exists")) {
        return
      }
    }
    throw "vercel project add failed: $text"
  }
  $output | Out-Host
}

function Resolve-ProjectScopeForLink([string]$ProjectName) {
  if ([string]::IsNullOrWhiteSpace($ProjectName)) { return "" }
  $token = [string]$env:VERCEL_TOKEN
  if ([string]::IsNullOrWhiteSpace($token)) { return "" }
  try {
    $path = "/v9/projects?name=$([uri]::EscapeDataString($ProjectName))&limit=20"
    $resp = Invoke-VercelApiGet -Path $path -Token $token -Scope ""
    if ($null -eq $resp -or $null -eq $resp.projects) { return "" }
    $hit = $resp.projects | Where-Object { [string]$_.name -eq $ProjectName } | Select-Object -First 1
    if ($null -eq $hit) { return "" }

    $accountId = ""
    if ($hit.PSObject.Properties.Name -contains "accountId" -and $hit.accountId) {
      $accountId = [string]$hit.accountId
    }
    if ([string]::IsNullOrWhiteSpace($accountId)) { return "" }
    if ($accountId.StartsWith("team_")) {
      $slug = Try-ResolveTeamSlugFromTeamId -TeamId $accountId -Token $token
      if (-not [string]::IsNullOrWhiteSpace($slug)) { return $slug }
      return $accountId
    }
    return ""
  } catch {
    return ""
  }
}

function Link-VercelProject([string]$ProjectName, [string]$Scope) {
  Write-Step "Linking local folder to Vercel project..."
  $Scope = Normalize-ScopeForCli -Scope $Scope
  $args = @("link", "--yes", "--project", $ProjectName)
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  $args += (Get-VercelTokenArgs)

  $res = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
  $res.Output | Out-Host
  if ($res.ExitCode -eq 0) { return }

  # Fallback: if scope is empty, resolve owner scope from API and retry.
  if ([string]::IsNullOrWhiteSpace($Scope)) {
    $resolvedScope = Normalize-ScopeForCli -Scope (Resolve-ProjectScopeForLink -ProjectName $ProjectName)
    if (-not [string]::IsNullOrWhiteSpace($resolvedScope)) {
      Write-Host "Link retry with resolved scope '$resolvedScope'..." -ForegroundColor DarkYellow
      $retryArgs = @("link", "--yes", "--project", $ProjectName, "--scope", $resolvedScope) + (Get-VercelTokenArgs)
      $retry = Invoke-NativeSafe -FilePath $VercelExe -Arguments $retryArgs
      $retry.Output | Out-Host
      if ($retry.ExitCode -eq 0) { return }
    }
  }

  throw "vercel link failed."
}

function Set-VercelEnv([string]$Name, [string]$Value, [string]$Target, [string]$Scope) {
  $Scope = Normalize-ScopeForCli -Scope $Scope
  $args = @("env", "add", $Name, $Target, "--value", $Value, "--force", "--yes", "--no-sensitive")
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  $args += (Get-VercelTokenArgs)
  $res = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
  $res.Output | Out-Host
  if ($res.ExitCode -ne 0) {
    throw "Failed to set env var $Name for $Target."
  }
}

function New-RandomPackageName {
  $chars = "abcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
  $suffix = -join (1..10 | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
  return "host-$suffix"
}

function New-RandomPackageVersion {
  $major = Get-Random -Minimum 1 -Maximum 4
  $minor = Get-Random -Minimum 0 -Maximum 20
  $patch = Get-Random -Minimum 0 -Maximum 30
  return "$major.$minor.$patch"
}

function New-RandomPackageDescription {
  $descriptions = @(
    "Lightweight hosting edge relay for low-bandwidth delivery",
    "Optimized download gateway for shared hosting workloads",
    "Traffic-shaped relay runtime for static and media hosting",
    "Resource-friendly transfer bridge for multi-tenant hosting",
    "Adaptive download routing layer for budget hosting plans",
    "Low-overhead HTTP delivery relay for content hosting",
    "Bandwidth-governed relay node for file delivery services",
    "Edge proxy core for controlled-speed hosting and downloads"
  )
  return ($descriptions | Get-Random)
}

function New-RandomVercelConfigName {
  $chars = "abcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
  $suffix = -join (1..10 | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
  return "edge-$suffix"
}

function Prepare-RandomizedPackageMetadataForDeploy {
  $pkgPath = Join-Path $scriptDir "package.json"
  if (-not (Test-Path $pkgPath)) {
    return @{
      Modified = $false
      PackagePath = $pkgPath
      OriginalContent = ""
    }
  }

  $original = Get-Content -Path $pkgPath -Raw
  try {
    $obj = $original | ConvertFrom-Json
  } catch {
    Write-Host "package.json parse failed; deploying without metadata randomization." -ForegroundColor DarkYellow
    return @{
      Modified = $false
      PackagePath = $pkgPath
      OriginalContent = $original
    }
  }

  $randomName = New-RandomPackageName
  $randomVersion = New-RandomPackageVersion
  $randomDesc = New-RandomPackageDescription

  if ($obj.PSObject.Properties.Name -contains "name") {
    $obj.name = $randomName
  } else {
    $obj | Add-Member -NotePropertyName "name" -NotePropertyValue $randomName
  }
  if ($obj.PSObject.Properties.Name -contains "version") {
    $obj.version = $randomVersion
  } else {
    $obj | Add-Member -NotePropertyName "version" -NotePropertyValue $randomVersion
  }
  if ($obj.PSObject.Properties.Name -contains "description") {
    $obj.description = $randomDesc
  } else {
    $obj | Add-Member -NotePropertyName "description" -NotePropertyValue $randomDesc
  }

  $json = $obj | ConvertTo-Json -Depth 50
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($pkgPath, $json, $utf8NoBom)

  return @{
    Modified = $true
    PackagePath = $pkgPath
    OriginalContent = $original
  }
}

function Restore-PackageMetadataAfterDeploy($state) {
  if ($null -eq $state) { return }
  if (-not $state.Modified) { return }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($state.PackagePath, [string]$state.OriginalContent, $utf8NoBom)
  # keep local files clean after deploy
}

function Prepare-RandomizedVercelConfigForDeploy {
  $vercelPath = Join-Path $scriptDir "vercel.json"
  if (-not (Test-Path $vercelPath)) {
    return @{
      Modified = $false
      ConfigPath = $vercelPath
      OriginalContent = ""
    }
  }

  $original = Get-Content -Path $vercelPath -Raw
  try {
    $obj = $original | ConvertFrom-Json
  } catch {
    Write-Host "vercel.json parse failed; deploying without vercel.json randomization." -ForegroundColor DarkYellow
    return @{
      Modified = $false
      ConfigPath = $vercelPath
      OriginalContent = $original
    }
  }

  $randomName = New-RandomVercelConfigName
  if ($obj.PSObject.Properties.Name -contains "name") {
    $obj.name = $randomName
  } else {
    $obj | Add-Member -NotePropertyName "name" -NotePropertyValue $randomName
  }

  $json = $obj | ConvertTo-Json -Depth 50
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($vercelPath, $json, $utf8NoBom)

  return @{
    Modified = $true
    ConfigPath = $vercelPath
    OriginalContent = $original
  }
}

function Restore-VercelConfigAfterDeploy($state) {
  if ($null -eq $state) { return }
  if (-not $state.Modified) { return }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($state.ConfigPath, [string]$state.OriginalContent, $utf8NoBom)
  # keep local files clean after deploy
}

function Build-RewriteSecureVercelJson([string]$TargetDomain, [string]$RelayPath, [string]$PublicRelayPath, [string]$RelayKey) {
  $target = $TargetDomain.TrimEnd("/")
  $up = Normalize-PathLike -PathValue $RelayPath
  $pub = Normalize-PathLike -PathValue $PublicRelayPath
  if ([string]::IsNullOrWhiteSpace($pub)) { $pub = "/api" }
  $dest = "$target$up"
  if (-not $dest.EndsWith("/")) { $dest = "$dest/" }
  $rk = ([string]$RelayKey).Trim()
  $rewrites = @()
  if (-not [string]::IsNullOrWhiteSpace($rk)) {
    $rewrites += [ordered]@{
      source = "$pub/(.*)"
      has = @(
        [ordered]@{
          type = "header"
          key = "x-relay-key"
          value = $rk
        }
      )
      destination = "$dest`$1"
    }
    $rewrites += [ordered]@{
      source = "$pub"
      has = @(
        [ordered]@{
          type = "header"
          key = "x-relay-key"
          value = $rk
        }
      )
      destination = $dest
    }
  } else {
    $rewrites += [ordered]@{
      source = "$pub/(.*)"
      destination = "$dest`$1"
    }
    $rewrites += [ordered]@{
      source = "$pub"
      destination = $dest
    }
  }
  $rewrites += [ordered]@{
    source = "/(.*)"
    destination = "/index.html"
  }
  $obj = [ordered]@{
    version = 2
    rewrites = $rewrites
    trailingSlash = $false
  }
  return ($obj | ConvertTo-Json -Depth 20)
}

function Prepare-RewriteSecureConfigForDeploy([string]$TargetDomain, [string]$RelayPath, [string]$PublicRelayPath, [string]$RelayKey) {
  $vercelPath = Join-Path $scriptDir "vercel.json"
  $original = ""
  if (Test-Path $vercelPath) { $original = Get-Content -Path $vercelPath -Raw }
  $json = Build-RewriteSecureVercelJson -TargetDomain $TargetDomain -RelayPath $RelayPath -PublicRelayPath $PublicRelayPath -RelayKey $RelayKey
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($vercelPath, $json, $utf8NoBom)
  return @{
    Modified = $true
    ConfigPath = $vercelPath
    OriginalContent = $original
  }
}

function Deploy-Production(
  [string]$Scope,
  [string]$Region = "",
  [string]$Runtime = "node",
  [string]$TargetDomain = "",
  [string]$RelayPath = "",
  [string]$PublicRelayPath = "",
  [string]$RelayKey = ""
) {
  Write-Step "Deploying to production..."
  $Scope = Normalize-ScopeForCli -Scope $Scope
  $randomizeState = Prepare-RandomizedPackageMetadataForDeploy
  $vercelRandomizeState = $null
  $regionState = $null
  try {
    $linked = Get-LinkedProjectInfo -ProjectRoot $scriptDir
    if (-not [string]::IsNullOrWhiteSpace($linked.ProjectName)) {
      $authSync = Disable-ProjectVercelAuthentication -ProjectName $linked.ProjectName -Scope $Scope -TokenStorePath $tokenStorePath
      $script:LastVercelAuthStatus = [string]$authSync.Status
    } else {
      $script:LastVercelAuthStatus = "unknown"
    }

    if ($Runtime -eq "rewrite") {
      $vercelRandomizeState = Prepare-RewriteSecureConfigForDeploy -TargetDomain $TargetDomain -RelayPath $RelayPath -PublicRelayPath $PublicRelayPath -RelayKey $RelayKey
      if ([string]::IsNullOrWhiteSpace(([string]$RelayKey).Trim())) {
        Write-Host "Rewrite mode: no relay key set (no x-relay-key required)." -ForegroundColor DarkYellow
      } else {
        Write-Host "Rewrite secure mode: x-relay-key lock enabled." -ForegroundColor DarkYellow
      }
    } else {
      $vercelRandomizeState = Prepare-RandomizedVercelConfigForDeploy
    }
    if ($Runtime -eq "node" -and -not [string]::IsNullOrWhiteSpace($Region)) {
      $regionState = Set-VercelFunctionRegion -Region $Region
    }
    $args = @("deploy", "--prod", "--yes")
    if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }

    $result = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
    $lines = $result.Output
    if ($result.ExitCode -ne 0) {
      $errText = (($lines | Out-String).Trim())
      if ([string]::IsNullOrWhiteSpace($errText)) { $errText = "unknown deploy failure" }
      throw "vercel deploy failed: $errText"
    }

    $alias = ""
    $prod = ""
    foreach ($line in $lines) {
      if ($line -match "Aliased:\s*(https://\S+)") { $alias = $Matches[1] }
      if ($line -match "Production:\s*(https://\S+)") { $prod = $Matches[1] }
      if ([string]::IsNullOrWhiteSpace($prod) -and $line -match '^https://[^\s]+\.vercel\.app$') { $prod = $line.Trim() }
    }

    return @{
      Alias = $alias
      Production = $prod
    }
  } finally {
    if ($null -ne $regionState) { Restore-VercelConfigAfterDeploy -state $regionState }
    if ($null -ne $vercelRandomizeState) { Restore-VercelConfigAfterDeploy -state $vercelRandomizeState }
    Restore-PackageMetadataAfterDeploy -state $randomizeState
  }
}

function Get-LinkedProjectInfo([string]$ProjectRoot) {
  $projectFile = Join-Path $ProjectRoot ".vercel\project.json"
  if (-not (Test-Path $projectFile)) {
    return @{
      IsLinked = $false
      ProjectName = ""
      ProjectId = ""
      Scope = ""
    }
  }

  try {
    $obj = Get-Content $projectFile -Raw | ConvertFrom-Json
  } catch {
    return @{
      IsLinked = $false
      ProjectName = ""
      ProjectId = ""
      Scope = ""
    }
  }

  $name = ""
  if ($obj.PSObject.Properties.Name -contains "projectName" -and $obj.projectName) { $name = [string]$obj.projectName }
  $projectId = ""
  if ($obj.PSObject.Properties.Name -contains "projectId" -and $obj.projectId) { $projectId = [string]$obj.projectId }
  $scope = ""
  if ($obj.PSObject.Properties.Name -contains "orgId" -and $obj.orgId) {
    $scope = Normalize-ScopeForCli -Scope ([string]$obj.orgId)
  }

  return @{
    IsLinked = $true
    ProjectName = $name
    ProjectId = $projectId
    Scope = $scope
  }
}

function Show-DeploySummary($deployInfo) {
  Write-Host ""
  Write-Host "==============================================" -ForegroundColor Green
  Write-Host "Deployment complete." -ForegroundColor Green
  if ($deployInfo.Production) { Write-Host "Production: $($deployInfo.Production)" -ForegroundColor Green }
  if ($deployInfo.Alias) { Write-Host "Aliased:    $($deployInfo.Alias)" -ForegroundColor Green }
  if ($deployInfo.Alias -match 'https://([^/]+)') {
    Write-Host ""
    Write-Host ("Use this in your client Host field: {0}" -f $Matches[1]) -ForegroundColor Cyan
  }
  Write-Host "==============================================" -ForegroundColor Green
  Write-Host ""
}

function Get-LinkedTeamId([string]$ProjectRoot) {
  $projectFile = Join-Path $ProjectRoot ".vercel\project.json"
  if (-not (Test-Path $projectFile)) { return "" }
  try {
    $obj = Get-Content $projectFile -Raw | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains "orgId" -and $obj.orgId) {
      $oid = [string]$obj.orgId
      if ($oid.StartsWith("team_")) { return $oid }
    }
  } catch {}
  return ""
}

function Collect-NewDeploymentConfig([string]$DefaultScope) {
  Write-Step "Collecting config values..."
  $projectNameInput = Read-Optional "Project name on Vercel (leave empty for random)"
  $projectName = if ([string]::IsNullOrWhiteSpace($projectNameInput)) { New-RandomProjectName } else { $projectNameInput }
  $DefaultScope = Normalize-ScopeForCli -Scope $DefaultScope
  if ([string]::IsNullOrWhiteSpace($DefaultScope)) {
    $scope = Read-Host "Scope slug/team (optional, press Enter to skip)"
  } else {
    $scope = Read-Default "Scope slug/team" $DefaultScope
  }
  $scope = Normalize-ScopeForCli -Scope $scope
  if (-not [string]::IsNullOrWhiteSpace($scope) -and -not (Validate-Scope -Scope $scope)) {
    throw "Scope '$scope' does not exist. Enter a valid Vercel team slug."
  }
  $targetDomain = Read-Required "TARGET_DOMAIN (MUST be your foreign server inbound domain+port, example: https://your-domain.com:443)"
  Write-Host "RELAY_PATH guide: open your foreign server inbound, set a Path starting with '/'. Enter EXACT same value here." -ForegroundColor DarkYellow
  $relayPath = Normalize-PathLike (Read-Required "RELAY_PATH (example: /api or /freedom)")
  $publicRelayPath = $relayPath
  Write-Host ("PUBLIC_RELAY_PATH auto-set to RELAY_PATH: {0}" -f $publicRelayPath) -ForegroundColor DarkCyan
  $landingTemplate = Read-Optional "LANDING_TEMPLATE (optional template folder name; empty = random each build)"
  $mode = Choose-DeploymentMode
  $maxInflight = $mode.MaxInflight
  $maxUpBps = $mode.MaxUpBps
  $maxDownBps = $mode.MaxDownBps
  $upstreamTimeoutMs = $mode.UpstreamTimeoutMs
  $successLogSampleRate = Read-Default "SUCCESS_LOG_SAMPLE_RATE" "0"
  $successLogMinDurationMs = Read-Default "SUCCESS_LOG_MIN_DURATION_MS" "3000"
  $errorLogMinIntervalMs = Read-Default "ERROR_LOG_MIN_INTERVAL_MS" "5000"
  $selectedRegion = if ($mode.Runtime -eq "node") { Choose-FunctionRegion -TargetDomain $targetDomain } else { "n/a (rewrite mode)" }
  $relayKey = ""
  if ($mode.Runtime -eq "rewrite") {
    $relayKey = Read-Optional "RELAY_KEY (optional in rewrite mode; empty = no x-relay-key required)"
  }

  Write-Step "Environment values selected:"
  Write-Host "TARGET_DOMAIN = $targetDomain"
  Write-Host "PROJECT_NAME  = $projectName"
  Write-Host "DEPLOY_MODE   = $($mode.ModeKey)"
  Write-Host "RUNTIME       = $($mode.Runtime)"
  if ($mode.Runtime -eq "node") {
    Write-Host ("FLUID_COMPUTE = {0}" -f $(if ($mode.FluidEnabled) { "on" } else { "off" }))
    Write-Host ("FUNCTION_TIMEOUT_SEC     = {0}" -f $mode.FunctionTimeoutSec)
  }
  Write-Host "RELAY_PATH    = $relayPath"
  Write-Host "PUBLIC_RELAY_PATH = $publicRelayPath"
  if (-not [string]::IsNullOrWhiteSpace($landingTemplate)) { Write-Host "LANDING_TEMPLATE = $landingTemplate" } else { Write-Host "LANDING_TEMPLATE = (random)" }
  if ($mode.Runtime -eq "node") {
    Write-Host "MAX_INFLIGHT  = $maxInflight"
    Write-Host "MAX_UP_BPS    = $maxUpBps"
    Write-Host "MAX_DOWN_BPS  = $maxDownBps"
    Write-Host "UPSTREAM_TIMEOUT_MS        = $upstreamTimeoutMs"
  } else {
    if ([string]::IsNullOrWhiteSpace($relayKey)) {
      Write-Host "REWRITE_SECURITY_HEADER = (disabled)"
      Write-Host "RELAY_KEY               = (not set)"
    } else {
      Write-Host "REWRITE_SECURITY_HEADER = x-relay-key"
      Write-Host "RELAY_KEY               = (set)"
    }
  }
  Write-Host "SUCCESS_LOG_SAMPLE_RATE    = $successLogSampleRate"
  Write-Host "SUCCESS_LOG_MIN_DURATION_MS= $successLogMinDurationMs"
  Write-Host "ERROR_LOG_MIN_INTERVAL_MS  = $errorLogMinIntervalMs"
  Write-Host "FUNCTION_REGION            = $selectedRegion"

  return @{
    ProjectName = $projectName
    Scope = $scope
    DeployMode = $mode.ModeKey
    Runtime = $mode.Runtime
    FluidEnabled = [bool]$mode.FluidEnabled
    FunctionTimeoutSec = [int]$mode.FunctionTimeoutSec
    RelayKey = $relayKey
    TargetDomain = $targetDomain
    RelayPath = $relayPath
    PublicRelayPath = $publicRelayPath
    LandingTemplate = $landingTemplate
    MaxInflight = $maxInflight
    MaxUpBps = $maxUpBps
    MaxDownBps = $maxDownBps
    UpstreamTimeoutMs = $upstreamTimeoutMs
    SuccessLogSampleRate = $successLogSampleRate
    SuccessLogMinDurationMs = $successLogMinDurationMs
    ErrorLogMinIntervalMs = $errorLogMinIntervalMs
    RunStressAfterDeploy = [bool]$mode.RunStressAfterDeploy
    Region = $selectedRegion
  }
}

function Export-ShareableConfigSummary($cfg, [string]$AliasUrl = "") {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $path = Join-Path $scriptDir ("build-profile-{0}.txt" -f $stamp)
  $lines = @()
  $lines += "XHTTPRelayECO Build Profile Summary"
  $lines += "generated_at=$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))"
  $lines += "deploy_mode=$($cfg.DeployMode)"
  $lines += "runtime=$($cfg.Runtime)"
  $lines += "fluid_compute=$($cfg.FluidEnabled)"
  $lines += "function_timeout_sec=$($cfg.FunctionTimeoutSec)"
  $authState = "unknown"
  if ($cfg.ContainsKey("VercelAuthentication") -and -not [string]::IsNullOrWhiteSpace([string]$cfg.VercelAuthentication)) {
    $authState = [string]$cfg.VercelAuthentication
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$script:LastVercelAuthStatus)) {
    $authState = [string]$script:LastVercelAuthStatus
  }
  $lines += "vercel_authentication=$authState"
  $lines += "relay_path=$($cfg.RelayPath)"
  $lines += "public_relay_path=$($cfg.PublicRelayPath)"
  $lines += "region=$($cfg.Region)"
  $lines += "max_inflight=$($cfg.MaxInflight)"
  $lines += "max_up_bps=$($cfg.MaxUpBps)"
  $lines += "max_down_bps=$($cfg.MaxDownBps)"
  $lines += "upstream_timeout_ms=$($cfg.UpstreamTimeoutMs)"
  $lines += "success_log_sample_rate=$($cfg.SuccessLogSampleRate)"
  $lines += "success_log_min_duration_ms=$($cfg.SuccessLogMinDurationMs)"
  $lines += "error_log_min_interval_ms=$($cfg.ErrorLogMinIntervalMs)"
  if (-not [string]::IsNullOrWhiteSpace($cfg.RelayKey)) { $lines += "relay_key=(set)" }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($path, $lines, $utf8NoBom)
  Write-Host ("Shareable config summary saved: {0}" -f $path) -ForegroundColor Green
}

function Apply-ProductionEnv($cfg) {
  Write-Step "Setting environment variables for production..."
  Set-VercelEnv -Name "TARGET_DOMAIN" -Value $cfg.TargetDomain -Target "production" -Scope $cfg.Scope
  Set-VercelEnv -Name "RELAY_PATH" -Value $cfg.RelayPath -Target "production" -Scope $cfg.Scope
  Set-VercelEnv -Name "PUBLIC_RELAY_PATH" -Value $cfg.PublicRelayPath -Target "production" -Scope $cfg.Scope
  if (-not [string]::IsNullOrWhiteSpace($cfg.LandingTemplate)) {
    Set-VercelEnv -Name "LANDING_TEMPLATE" -Value $cfg.LandingTemplate -Target "production" -Scope $cfg.Scope
  }
  if ($cfg.Runtime -eq "node") {
    Set-VercelEnv -Name "MAX_INFLIGHT" -Value $cfg.MaxInflight -Target "production" -Scope $cfg.Scope
    Set-VercelEnv -Name "MAX_UP_BPS" -Value $cfg.MaxUpBps -Target "production" -Scope $cfg.Scope
    Set-VercelEnv -Name "MAX_DOWN_BPS" -Value $cfg.MaxDownBps -Target "production" -Scope $cfg.Scope
  }
  Set-VercelEnv -Name "UPSTREAM_TIMEOUT_MS" -Value $cfg.UpstreamTimeoutMs -Target "production" -Scope $cfg.Scope
  Set-VercelEnv -Name "SUCCESS_LOG_SAMPLE_RATE" -Value $cfg.SuccessLogSampleRate -Target "production" -Scope $cfg.Scope
  Set-VercelEnv -Name "SUCCESS_LOG_MIN_DURATION_MS" -Value $cfg.SuccessLogMinDurationMs -Target "production" -Scope $cfg.Scope
  Set-VercelEnv -Name "ERROR_LOG_MIN_INTERVAL_MS" -Value $cfg.ErrorLogMinIntervalMs -Target "production" -Scope $cfg.Scope
  if (-not [string]::IsNullOrWhiteSpace($cfg.RelayKey)) {
    Set-VercelEnv -Name "RELAY_KEY" -Value $cfg.RelayKey -Target "production" -Scope $cfg.Scope
  }
}

function Run-NewDeploymentFlow([string]$DefaultScope) {
  $cfg = Collect-NewDeploymentConfig -DefaultScope $DefaultScope
  Ensure-VercelProject -ProjectName $cfg.ProjectName -Scope $cfg.Scope
  Link-VercelProject -ProjectName $cfg.ProjectName -Scope $cfg.Scope
  Apply-ProductionEnv -cfg $cfg
  if ($cfg.Runtime -eq "node") {
    $null = Apply-ProjectRuntimeSettings -ProjectName $cfg.ProjectName -Scope $cfg.Scope -TokenStorePath $tokenStorePath -Region $cfg.Region -FunctionTimeoutSec $cfg.FunctionTimeoutSec -FluidEnabled $cfg.FluidEnabled
  }
  $deployInfo = Deploy-Production -Scope $cfg.Scope -Region $cfg.Region -Runtime $cfg.Runtime -TargetDomain $cfg.TargetDomain -RelayPath $cfg.RelayPath -PublicRelayPath $cfg.PublicRelayPath -RelayKey $cfg.RelayKey
  $cfg.VercelAuthentication = [string]$script:LastVercelAuthStatus
  Show-DeploySummary $deployInfo
  Export-ShareableConfigSummary -cfg $cfg -AliasUrl $deployInfo.Alias
  $runTests = Read-Default "Run essential health/smoke tests now? (Y/n)" "y"
  if ($runTests.ToLowerInvariant() -ne "n") {
    Run-HealthAndSmokeChecks -ProjectName $cfg.ProjectName -RelayPath $cfg.PublicRelayPath
    if ($cfg.RunStressAfterDeploy) {
      Write-Host "Running STRESS_TEST light pass automatically..." -ForegroundColor Yellow
      Run-LoadTestLite -ProjectName $cfg.ProjectName -RelayPath $cfg.PublicRelayPath
    }
    Read-Host "Health/smoke checks finished. Press Enter to continue"
  }
  Write-Host "Done."
}

function Run-UpdateEnvFlow([string]$Scope) {
  Write-Step "Update production env vars (required + profile defaults)..."
  $targetDomain = Read-Required "TARGET_DOMAIN (foreign inbound domain+port)"
  Write-Host "RELAY_PATH guide: this must EXACTLY match inbound path on your foreign server." -ForegroundColor DarkYellow
  $relayPath = Normalize-PathLike (Read-Required "RELAY_PATH (example: /api)")
  $publicRelayPath = $relayPath
  Write-Host ("PUBLIC_RELAY_PATH auto-set to RELAY_PATH: {0}" -f $publicRelayPath) -ForegroundColor DarkCyan
  $landingTemplate = Read-Optional "LANDING_TEMPLATE (optional template folder name; empty keeps previous/random)"
  $mode = Choose-DeploymentMode
  $maxInflight = $mode.MaxInflight
  $maxUpBps = $mode.MaxUpBps
  $maxDownBps = $mode.MaxDownBps
  $upstreamTimeoutMs = $mode.UpstreamTimeoutMs
  $successLogSampleRate = Read-Default "SUCCESS_LOG_SAMPLE_RATE" "0"
  $successLogMinDurationMs = Read-Default "SUCCESS_LOG_MIN_DURATION_MS" "3000"
  $errorLogMinIntervalMs = Read-Default "ERROR_LOG_MIN_INTERVAL_MS" "5000"
  $selectedRegion = if ($mode.Runtime -eq "node") { Choose-FunctionRegion -TargetDomain $targetDomain } else { "n/a (rewrite mode)" }
  $relayKey = ""
  if ($mode.Runtime -eq "rewrite") {
    $relayKey = Read-Optional "RELAY_KEY (optional in rewrite mode; empty = no x-relay-key required)"
  }

  Set-VercelEnv -Name "TARGET_DOMAIN" -Value $targetDomain -Target "production" -Scope $Scope
  Set-VercelEnv -Name "RELAY_PATH" -Value $relayPath -Target "production" -Scope $Scope
  Set-VercelEnv -Name "PUBLIC_RELAY_PATH" -Value $publicRelayPath -Target "production" -Scope $Scope
  if (-not [string]::IsNullOrWhiteSpace($landingTemplate)) {
    Set-VercelEnv -Name "LANDING_TEMPLATE" -Value $landingTemplate -Target "production" -Scope $Scope
  }
  if ($mode.Runtime -eq "node") {
    Set-VercelEnv -Name "MAX_INFLIGHT" -Value $maxInflight -Target "production" -Scope $Scope
    Set-VercelEnv -Name "MAX_UP_BPS" -Value $maxUpBps -Target "production" -Scope $Scope
    Set-VercelEnv -Name "MAX_DOWN_BPS" -Value $maxDownBps -Target "production" -Scope $Scope
  }
  Set-VercelEnv -Name "UPSTREAM_TIMEOUT_MS" -Value $upstreamTimeoutMs -Target "production" -Scope $Scope
  Set-VercelEnv -Name "SUCCESS_LOG_SAMPLE_RATE" -Value $successLogSampleRate -Target "production" -Scope $Scope
  Set-VercelEnv -Name "SUCCESS_LOG_MIN_DURATION_MS" -Value $successLogMinDurationMs -Target "production" -Scope $Scope
  Set-VercelEnv -Name "ERROR_LOG_MIN_INTERVAL_MS" -Value $errorLogMinIntervalMs -Target "production" -Scope $Scope
  if (-not [string]::IsNullOrWhiteSpace($relayKey)) {
    Set-VercelEnv -Name "RELAY_KEY" -Value $relayKey -Target "production" -Scope $Scope
  }
  $fnTimeoutSec = [int]$mode.FunctionTimeoutSec
  $linkInfo = Get-LinkedProjectInfo -ProjectRoot $scriptDir
  if ($mode.Runtime -eq "node" -and -not [string]::IsNullOrWhiteSpace($linkInfo.ProjectName)) {
    $null = Apply-ProjectRuntimeSettings -ProjectName $linkInfo.ProjectName -Scope $Scope -TokenStorePath $tokenStorePath -Region $selectedRegion -FunctionTimeoutSec $fnTimeoutSec -FluidEnabled $mode.FluidEnabled
  } else {
    Write-Host "Runtime settings sync skipped (rewrite mode or linked project not detected)." -ForegroundColor DarkYellow
  }
  $redeployNow = Read-Default "Redeploy now? (Y/n)" "y"
  if ($redeployNow.ToLowerInvariant() -eq "y") {
    $deployInfo = Deploy-Production -Scope $Scope -Region $selectedRegion -Runtime $mode.Runtime -TargetDomain $targetDomain -RelayPath $relayPath -PublicRelayPath $publicRelayPath -RelayKey $relayKey
    Show-DeploySummary $deployInfo
    $cfgSummary = @{
      ProjectName = $linkInfo.ProjectName
      Scope = $Scope
      DeployMode = $mode.ModeKey
      Runtime = $mode.Runtime
      FluidEnabled = [bool]$mode.FluidEnabled
      FunctionTimeoutSec = $fnTimeoutSec
      TargetDomain = $targetDomain
      RelayPath = $relayPath
      PublicRelayPath = $publicRelayPath
      LandingTemplate = $landingTemplate
      Region = $selectedRegion
      MaxInflight = $maxInflight
      MaxUpBps = $maxUpBps
      MaxDownBps = $maxDownBps
      UpstreamTimeoutMs = $upstreamTimeoutMs
      SuccessLogSampleRate = $successLogSampleRate
      SuccessLogMinDurationMs = $successLogMinDurationMs
      ErrorLogMinIntervalMs = $errorLogMinIntervalMs
      RelayKey = $relayKey
      VercelAuthentication = [string]$script:LastVercelAuthStatus
    }
    Export-ShareableConfigSummary -cfg $cfgSummary -AliasUrl $deployInfo.Alias
    $runTests = Read-Default "Run essential health/smoke tests now? (Y/n)" "y"
    if ($runTests.ToLowerInvariant() -ne "n") {
      $link = Get-LinkedProjectInfo -ProjectRoot $scriptDir
      if (-not [string]::IsNullOrWhiteSpace($link.ProjectName)) {
        Run-HealthAndSmokeChecks -ProjectName $link.ProjectName -RelayPath $publicRelayPath
        if ($mode.RunStressAfterDeploy) {
          Write-Host "Running STRESS_TEST light pass automatically..." -ForegroundColor Yellow
          Run-LoadTestLite -ProjectName $link.ProjectName -RelayPath $publicRelayPath
        }
        Read-Host "Health/smoke checks finished. Press Enter to continue"
      }
    }
  }
}

function Show-DeploymentList([string]$ProjectName, [string]$Scope) {
  Write-Step "Recent deployments..."
  $Scope = Normalize-ScopeForCli -Scope $Scope
  $args = @("list")
  if (-not [string]::IsNullOrWhiteSpace($ProjectName)) { $args += @($ProjectName) }
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  $result = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
  $result.Output | Out-Host
  if ($result.ExitCode -ne 0) {
    Write-Host "Could not list deployments with scoped project. Trying generic list..." -ForegroundColor DarkYellow
    $fallback = Invoke-NativeSafe -FilePath $VercelExe -Arguments @("list")
    $fallback.Output | Out-Host
  }
}

function Ensure-LinkedToProject([string]$ProjectName, [string]$Scope) {
  if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    throw "Project name is required."
  }
  Link-VercelProject -ProjectName $ProjectName -Scope $Scope
}

function Parse-ProjectListText([string[]]$Lines) {
  $projects = @()
  foreach ($line in $Lines) {
    if ($null -eq $line) { continue }
    $clean = [regex]::Replace([string]$line, '\x1B\[[0-9;]*[A-Za-z]', '')
    $trim = $clean.Trim()
    if ([string]::IsNullOrWhiteSpace($trim)) { continue }
    if ($trim.StartsWith(">")) { continue }
    if ($trim.StartsWith("-")) { continue }
    if ($trim -match '^(Projects|Name|Updated|ID|Inspect|No projects|Fetching|Retrieving|Error:|Warning:|Visit )') { continue }
    if ($trim -match '^https?://') { continue }

    $name = ($trim -split '\s+')[0]
    if ($name -match '^[a-zA-Z0-9][a-zA-Z0-9\-_\.]+$') {
      $projects += [PSCustomObject]@{
        Name = $name
        Id = ""
      }
    }
  }
  return @($projects | Sort-Object Name -Unique)
}

function Get-ProjectsFromVercel([string]$Scope) {
  $Scope = Normalize-ScopeForCli -Scope $Scope
  $args = @("project", "list", "--format", "json", "--no-color")
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  $result = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args

  if ($result.ExitCode -eq 0) {
    $raw = ($result.Output -join "`n")
    $raw = $raw -replace "`0", ""
    $raw = $raw.Trim()

    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      # Try to isolate JSON payload even if CLI prints extra lines before/after.
      $jsonCandidate = $raw
      $firstArray = $raw.IndexOf("[")
      $lastArray = $raw.LastIndexOf("]")
      $firstObject = $raw.IndexOf("{")
      $lastObject = $raw.LastIndexOf("}")

      if ($firstArray -ge 0 -and $lastArray -gt $firstArray) {
        $jsonCandidate = $raw.Substring($firstArray, $lastArray - $firstArray + 1)
      } elseif ($firstObject -ge 0 -and $lastObject -gt $firstObject) {
        $jsonCandidate = $raw.Substring($firstObject, $lastObject - $firstObject + 1)
      }

      try {
        $parsed = $jsonCandidate | ConvertFrom-Json

        $items = @()
        if ($parsed -is [System.Array]) {
          $items = $parsed
        } elseif ($parsed.PSObject.Properties.Name -contains "projects") {
          $items = @($parsed.projects)
        } else {
          $items = @($parsed)
        }

        $projects = @()
        foreach ($item in $items) {
          $name = ""
          if ($item.PSObject.Properties.Name -contains "name" -and $item.name) { $name = [string]$item.name }
          if ([string]::IsNullOrWhiteSpace($name)) { continue }

          $projectId = ""
          if ($item.PSObject.Properties.Name -contains "id" -and $item.id) { $projectId = [string]$item.id }
          $projects += [PSCustomObject]@{
            Name = $name
            Id = $projectId
          }
        }

        if ($projects.Count -gt 0) {
          return @($projects | Sort-Object Name -Unique)
        }
      } catch {
        # ignore and continue to text parsing fallbacks below
      }
    }

    $parsedText = Parse-ProjectListText -Lines $result.Output
    if ($parsedText.Count -gt 0) { return $parsedText }
  }

  # Fallback for CLI variants/versions where JSON format is unavailable.
  $fallbackCommands = @(
    @("project", "list", "--no-color"),
    @("projects", "list", "--no-color"),
    @("project", "ls", "--no-color"),
    @("projects", "ls", "--no-color")
  )

  foreach ($cmd in $fallbackCommands) {
    $fallbackArgs = @($cmd)
    if (-not [string]::IsNullOrWhiteSpace($Scope)) { $fallbackArgs += @("--scope", $Scope) }
    $fallback = Invoke-NativeSafe -FilePath $VercelExe -Arguments $fallbackArgs
    if ($fallback.ExitCode -ne 0) { continue }

    $parsedText = Parse-ProjectListText -Lines $fallback.Output
    if ($parsedText.Count -gt 0) { return $parsedText }
  }

  throw "Could not parse Vercel project list. Try auth mode 2 (token) or set a valid scope."
}

function Select-ProjectFromList([string]$Scope) {
  Write-Step "Loading projects from Vercel..."
  try {
    $projects = Get-ProjectsFromVercel -Scope $Scope
  } catch {
    Write-Host "Could not load project list: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Tip: continue with option 5 (Deploy as NEW project), or retry with token auth." -ForegroundColor DarkYellow
    return $null
  }
  if ($projects.Count -eq 0) {
    Write-Host "No projects found in this scope." -ForegroundColor DarkYellow
    return $null
  }

  Write-Host ""
  Write-Host "Projects:" -ForegroundColor Cyan
  for ($i = 0; $i -lt $projects.Count; $i++) {
    Write-Host ("[{0}] {1}" -f ($i + 1), $projects[$i].Name)
  }
  Write-Host "[0] Cancel"

  while ($true) {
    $choiceRaw = Read-Default "Select project number" "0"
    $n = 0
    if (-not [int]::TryParse($choiceRaw, [ref]$n)) {
      Write-Host "Invalid number." -ForegroundColor Red
      continue
    }
    if ($n -eq 0) { return $null }
    if ($n -ge 1 -and $n -le $projects.Count) {
      return $projects[$n - 1]
    }
    Write-Host "Out of range." -ForegroundColor Red
  }
}

function Select-ProjectOrNewForFirstRun([string]$Scope) {
  Write-Step "No linked project found. Loading your Vercel projects..."
  try {
    $projects = Get-ProjectsFromVercel -Scope $Scope
  } catch {
    Write-Host "Could not load projects list. Continuing with NEW-project flow." -ForegroundColor DarkYellow
    Write-Host "Details: $($_.Exception.Message)" -ForegroundColor DarkGray
    $projects = @()
  }

  Write-Host ""
  Write-Host "Choose a target to continue:" -ForegroundColor Cyan
  if ($projects.Count -gt 0) {
    for ($i = 0; $i -lt $projects.Count; $i++) {
      Write-Host ("[{0}] Use existing project: {1}" -f ($i + 1), $projects[$i].Name)
    }
  } else {
    Write-Host "No existing projects found in current scope/account." -ForegroundColor DarkYellow
  }

  $newIndex = $projects.Count + 1
  Write-Host ("[{0}] Deploy as NEW project" -f $newIndex)

  while ($true) {
    $choiceRaw = Read-Host "Select one option"
    $n = 0
    if (-not [int]::TryParse($choiceRaw, [ref]$n)) {
      Write-Host "Invalid number." -ForegroundColor Red
      continue
    }

    if ($n -eq $newIndex) {
      return @{
        Mode = "new"
        ProjectName = ""
      }
    }

    if ($n -ge 1 -and $n -le $projects.Count) {
      return @{
        Mode = "existing"
        ProjectName = $projects[$n - 1].Name
      }
    }

    Write-Host "Out of range. Choose one of the listed options." -ForegroundColor Red
  }
}

function Get-VercelApiToken([string]$TokenStorePath) {
  if (-not [string]::IsNullOrWhiteSpace($env:VERCEL_TOKEN)) {
    return $env:VERCEL_TOKEN
  }
  $saved = Load-TokenSecure -Path $TokenStorePath
  if (-not [string]::IsNullOrWhiteSpace($saved)) {
    return $saved
  }
  return ""
}

function New-ScopeQuery([string]$Scope) {
  if ([string]::IsNullOrWhiteSpace($Scope)) { return "" }
  $s = $Scope.Trim()
  if ($s.StartsWith("team_")) {
    return ("teamId={0}" -f [uri]::EscapeDataString($s))
  }
  return ("slug={0}" -f [uri]::EscapeDataString($s))
}

function Invoke-VercelApiGet([string]$Path, [string]$Token, [string]$Scope) {
  if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "Vercel token is required for API mode."
  }
  $url = "https://api.vercel.com$Path"
  $scopeQuery = New-ScopeQuery -Scope $Scope
  if (-not [string]::IsNullOrWhiteSpace($scopeQuery)) {
    if ($url.Contains("?")) { $url = "$url&$scopeQuery" } else { $url = "$url?$scopeQuery" }
  }
  $headers = @{ Authorization = "Bearer $Token" }
  return Invoke-RestMethod -Method Get -Uri $url -Headers $headers
}

function Invoke-VercelApiPatch([string]$Path, [string]$Token, [string]$Scope, [hashtable]$Body) {
  if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "Vercel token is required for API mode."
  }
  $url = "https://api.vercel.com$Path"
  $scopeQuery = New-ScopeQuery -Scope $Scope
  if (-not [string]::IsNullOrWhiteSpace($scopeQuery)) {
    if ($url.Contains("?")) { $url = "$url&$scopeQuery" } else { $url = "$url?$scopeQuery" }
  }
  $headers = @{
    Authorization = "Bearer $Token"
    "Content-Type" = "application/json"
  }
  $json = $Body | ConvertTo-Json -Depth 20
  return Invoke-RestMethod -Method Patch -Uri $url -Headers $headers -Body $json
}

function Invoke-VercelApiDelete([string]$Path, [string]$Token, [string]$Scope) {
  if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "Vercel token is required for API mode."
  }
  $url = "https://api.vercel.com$Path"
  $scopeQuery = New-ScopeQuery -Scope $Scope
  if (-not [string]::IsNullOrWhiteSpace($scopeQuery)) {
    if ($url.Contains("?")) { $url = "$url&$scopeQuery" } else { $url = "$url?$scopeQuery" }
  }
  $headers = @{ Authorization = "Bearer $Token" }
  return Invoke-RestMethod -Method Delete -Uri $url -Headers $headers
}

function Try-ResolveTeamSlugFromTeamId([string]$TeamId, [string]$Token) {
  if ([string]::IsNullOrWhiteSpace($TeamId)) { return "" }
  if (-not $TeamId.StartsWith("team_")) { return "" }
  try {
    $resp = Invoke-VercelApiGet -Path "/v2/teams?limit=100" -Token $Token -Scope ""
    if ($null -eq $resp -or $null -eq $resp.teams) { return "" }
    $hit = $resp.teams | Where-Object { [string]$_.id -eq $TeamId } | Select-Object -First 1
    if ($null -eq $hit) { return "" }
    return [string]$hit.slug
  } catch {
    return ""
  }
}

function Convert-ApiTimestampToText($ts) {
  if ($null -eq $ts) { return "-" }
  try {
    $n = [int64]$ts
    if ($n -le 0) { return "-" }
    $dto = [DateTimeOffset]::FromUnixTimeMilliseconds($n).ToLocalTime()
    return $dto.ToString("yyyy-MM-dd HH:mm:ss")
  } catch {
    return [string]$ts
  }
}

function Get-ProjectDeploymentsApi([string]$ProjectId, [string]$Scope, [string]$Token, [int]$Limit = 20) {
  if ([string]::IsNullOrWhiteSpace($ProjectId)) { return @() }
  $path = "/v6/deployments?projectId=$([uri]::EscapeDataString($ProjectId))&limit=$Limit"
  $resp = Invoke-VercelApiGet -Path $path -Token $Token -Scope $Scope
  if ($null -eq $resp -or $null -eq $resp.deployments) { return @() }
  return @($resp.deployments)
}

function Get-ProjectEnvEntriesApi([string]$ProjectName, [string]$Scope, [string]$Token, [int]$Limit = 200) {
  if ([string]::IsNullOrWhiteSpace($ProjectName)) { return @() }
  # Ask API for decrypted values when possible (depends on token/permissions/type).
  $path = "/v10/projects/$([uri]::EscapeDataString($ProjectName))/env?limit=$Limit&decrypt=true"
  $resp = Invoke-VercelApiGet -Path $path -Token $Token -Scope $Scope
  if ($null -eq $resp -or $null -eq $resp.envs) { return @() }
  return @($resp.envs)
}

function Normalize-EnvTargets($t) {
  if ($null -eq $t) { return @() }
  if ($t -is [System.Array]) {
    $arr = @()
    foreach ($x in $t) {
      if ($null -ne $x) {
        $s = [string]$x
        if (-not [string]::IsNullOrWhiteSpace($s)) { $arr += $s }
      }
    }
    return @($arr | Select-Object -Unique)
  }
  $single = [string]$t
  if ([string]::IsNullOrWhiteSpace($single)) { return @() }
  return @($single)
}

function Test-IsMaskedOrEncryptedEnvValue([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  $v = $Value.Trim()
  # Common Vercel masked/encrypted payload patterns returned by API.
  if ($v.StartsWith("eyJ2IjoidjIi")) { return $true }  # JSON v2 blob (base64-like prefix)
  if ($v.StartsWith("ENC[")) { return $true }
  # Long base64-looking tokens are usually not human-readable secrets.
  if ($v.Length -ge 80 -and $v -match '^[A-Za-z0-9+/=]+$') { return $true }
  return $false
}

function Get-EnvValuePreview($envObj) {
  try {
    $v = ""
    if ($envObj.PSObject.Properties.Name -contains "decrypted") {
      $dv = [string]$envObj.decrypted
      if (-not [string]::IsNullOrWhiteSpace($dv)) { $v = $dv }
    }
    if ([string]::IsNullOrWhiteSpace($v) -and $envObj.PSObject.Properties.Name -contains "decryptedValue") {
      $dv2 = [string]$envObj.decryptedValue
      if (-not [string]::IsNullOrWhiteSpace($dv2)) { $v = $dv2 }
    }
    if ([string]::IsNullOrWhiteSpace($v)) {
      $v = [string]$envObj.value
    }
    if (Test-IsMaskedOrEncryptedEnvValue -Value $v) { return "(hidden/sensitive)" }
    if ($v.Length -gt 90) { return ($v.Substring(0, 90) + "...") }
    return $v
  } catch {
    return "(hidden/sensitive)"
  }
}

function Parse-DotEnvFileToMap([string]$Path) {
  $map = @{}
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return $map }
  $lines = Get-Content $Path -ErrorAction SilentlyContinue
  foreach ($ln in $lines) {
    $line = [string]$ln
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $trim = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trim)) { continue }
    if ($trim.StartsWith("#")) { continue }
    if ($trim.StartsWith("export ")) { $trim = $trim.Substring(7).Trim() }
    $eq = $trim.IndexOf("=")
    if ($eq -le 0) { continue }

    $k = $trim.Substring(0, $eq).Trim()
    $v = $trim.Substring($eq + 1)
    if ([string]::IsNullOrWhiteSpace($k)) { continue }

    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
      $v = $v.Substring(1, $v.Length - 2) -replace '\\"', '"'
    } elseif ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) {
      $v = $v.Substring(1, $v.Length - 2)
    }

    $map[$k] = @{
      exists = $true
      value = [string]$v
      source = "cli_pull"
    }
  }
  return $map
}

function Get-EnvMapFromCliPull([string]$ProjectName, [string]$Scope, [string]$TokenStorePath) {
  $map = @{}
  $token = Get-VercelApiToken -TokenStorePath $TokenStorePath
  if ([string]::IsNullOrWhiteSpace($token)) { return $map }

  $Scope = Normalize-ScopeForCli -Scope $Scope
  $tmp = Join-Path $env:TEMP ("xhttprelay-env-" + [Guid]::NewGuid().ToString("N") + ".env")
  try {
    $args = @("env", "pull", $tmp, "--environment", "production", "--yes")
    if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
    $args += @("--token", $token)
    $res = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
    if ($res.ExitCode -ne 0) { return @{} }
    $map = Parse-DotEnvFileToMap -Path $tmp
    return $map
  } catch {
    return @{}
  } finally {
    try { if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch {}
  }
}

function Show-DeploymentEnvConfig([string]$ProjectName, [string]$Scope, [string]$TokenStorePath) {
  Write-Step "Deployment ENV inspector"
  $token = Get-VercelApiToken -TokenStorePath $TokenStorePath
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "No API token available. Use token auth mode first."
  }

  $projectId = Resolve-ProjectApiId -ProjectName $ProjectName -Scope $Scope -Token $token
  if ([string]::IsNullOrWhiteSpace($projectId)) {
    throw "Could not resolve project id via API."
  }

  $deps = Get-ProjectDeploymentsApi -ProjectId $projectId -Scope $Scope -Token $token -Limit 20
  $selectedDeployment = $null
  $selectedTarget = "production"

  if ($deps.Count -gt 0) {
    Write-Host "Choose deployment:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $deps.Count; $i++) {
      $d = $deps[$i]
      $target = [string]$d.target
      if ([string]::IsNullOrWhiteSpace($target)) { $target = "-" }
      $state = [string]$d.state
      if ([string]::IsNullOrWhiteSpace($state)) { $state = "-" }
      $created = Convert-ApiTimestampToText $d.createdAt
      $alias = "-"
      try {
        if ($null -ne $d.url -and -not [string]::IsNullOrWhiteSpace([string]$d.url)) {
          $alias = [string]$d.url
        }
      } catch {}
      Write-Host ("[{0}] {1} | target={2} | state={3} | {4}" -f ($i + 1), $created, $target, $state, $alias)
    }
    $pickRaw = Read-Default "Select deployment index" "1"
    $pick = 1
    [void][int]::TryParse($pickRaw, [ref]$pick)
    if ($pick -lt 1 -or $pick -gt $deps.Count) { $pick = 1 }
    $selectedDeployment = $deps[$pick - 1]
    $st = [string]$selectedDeployment.target
    if (-not [string]::IsNullOrWhiteSpace($st)) { $selectedTarget = $st }
  } else {
    Write-Host "No deployments returned by API. Showing project ENV list only." -ForegroundColor DarkYellow
  }

  Write-Host ""
  if ($null -ne $selectedDeployment) {
    Write-Host "Selected deployment summary:" -ForegroundColor Yellow
    Write-Host ("id:      {0}" -f [string]$selectedDeployment.uid)
    Write-Host ("target:  {0}" -f $selectedTarget)
    Write-Host ("state:   {0}" -f [string]$selectedDeployment.state)
    Write-Host ("created: {0}" -f (Convert-ApiTimestampToText $selectedDeployment.createdAt))
  } else {
    Write-Host ("Target fallback for filtering: {0}" -f $selectedTarget) -ForegroundColor Yellow
  }
  Write-Host ""

  $envs = Get-ProjectEnvEntriesApi -ProjectName $ProjectName -Scope $Scope -Token $token -Limit 200
  if ($envs.Count -eq 0) {
    Write-Host "No ENV entries found via API." -ForegroundColor DarkYellow
    return
  }

  $rows = @()
  foreach ($e in $envs) {
    $key = [string]$e.key
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    $targets = Normalize-EnvTargets $e.target
    $targetText = if ($targets.Count -gt 0) { ($targets -join ",") } else { "all/unknown" }
    $effective = $false
    if ($targets.Count -eq 0) {
      $effective = $true
    } elseif ($targets -contains $selectedTarget) {
      $effective = $true
    }
    $rows += [pscustomobject]@{
      Effective = $(if ($effective) { "yes" } else { "no" })
      Key = $key
      ValuePreview = (Get-EnvValuePreview -envObj $e)
      Targets = $targetText
      UpdatedAt = (Convert-ApiTimestampToText $e.updatedAt)
    }
  }

  Write-Host ("ENV entries for project '{0}' (effective target: {1})" -f $ProjectName, $selectedTarget) -ForegroundColor Cyan
  Write-Host "Note: sensitive values may be masked by Vercel API." -ForegroundColor DarkGray
  $rows |
    Sort-Object @{ Expression = "Effective"; Descending = $true }, @{ Expression = "Key"; Descending = $false } |
    Format-Table Effective, Key, ValuePreview, Targets, UpdatedAt -AutoSize |
    Out-Host

  $save = Read-Default "Save this ENV report to txt file? (Y/n)" "y"
  if ($save.ToLowerInvariant() -ne "n") {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $out = Join-Path $scriptDir ("env-report-{0}-{1}.txt" -f $ProjectName, $stamp)
    $header = @(
      "XHTTPRelayECO ENV Report",
      ("project={0}" -f $ProjectName),
      ("selected_target={0}" -f $selectedTarget),
      ("generated_at={0}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")),
      ""
    )
    $table = ($rows |
      Sort-Object @{ Expression = "Effective"; Descending = $true }, @{ Expression = "Key"; Descending = $false } |
      Format-Table Effective, Key, ValuePreview, Targets, UpdatedAt -AutoSize | Out-String)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($out, (($header -join [Environment]::NewLine) + [Environment]::NewLine + $table), $utf8NoBom)
    Write-Host ("ENV report saved: {0}" -f $out) -ForegroundColor Green
  }
}

function Build-ScopeCandidates([string]$Scope, [string]$Token, [string]$ProjectRoot = "") {
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($Scope)) {
    $candidates += $Scope
    if ($Scope.StartsWith("team_")) {
      $slugFromInputTeam = Try-ResolveTeamSlugFromTeamId -TeamId $Scope -Token $Token
      if (-not [string]::IsNullOrWhiteSpace($slugFromInputTeam)) { $candidates += $slugFromInputTeam }
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $linkedTeamId = Get-LinkedTeamId -ProjectRoot $ProjectRoot
    if (-not [string]::IsNullOrWhiteSpace($linkedTeamId)) {
      $candidates += $linkedTeamId
      $slugFromLinkedTeam = Try-ResolveTeamSlugFromTeamId -TeamId $linkedTeamId -Token $Token
      if (-not [string]::IsNullOrWhiteSpace($slugFromLinkedTeam)) { $candidates += $slugFromLinkedTeam }
    }
  }
  $candidates += ""
  return @($candidates | Where-Object { $_ -ne $null } | Select-Object -Unique)
}

function Get-ApiErrorText($errObj) {
  $msg = ""
  try {
    $msg = [string]$errObj.Exception.Message
  } catch {}
  try {
    $resp = $errObj.Exception.Response
    if ($null -ne $resp -and $resp.GetResponseStream) {
      $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
      $body = $reader.ReadToEnd()
      if (-not [string]::IsNullOrWhiteSpace($body)) {
        if ($body.Length -gt 280) { $body = $body.Substring(0, 280) + "..." }
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $body } else { $msg = "$msg | $body" }
      }
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "unknown api error" }
  return $msg
}

function Disable-ProjectVercelAuthentication([string]$ProjectName, [string]$Scope, [string]$TokenStorePath) {
  if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    return @{ Applied = $false; Status = "unknown"; Message = "project_missing" }
  }
  $token = Get-VercelApiToken -TokenStorePath $TokenStorePath
  if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "Deployment protection sync skipped: token not available for API." -ForegroundColor DarkYellow
    return @{ Applied = $false; Status = "unknown"; Message = "token_missing" }
  }

  $projectId = Resolve-ProjectApiId -ProjectName $ProjectName -Scope $Scope -Token $token
  if ([string]::IsNullOrWhiteSpace($projectId)) {
    Write-Host "Deployment protection sync skipped: could not resolve project id via API." -ForegroundColor DarkYellow
    return @{ Applied = $false; Status = "unknown"; Message = "project_id_missing" }
  }

  $pathCandidates = @(
    "/v9/projects/$([uri]::EscapeDataString($projectId))",
    "/v9/projects/$([uri]::EscapeDataString($ProjectName))"
  )
  $payloads = @(
    @{ ssoProtection = $null }
  )
  $scopeCandidates = Build-ScopeCandidates -Scope $Scope -Token $token -ProjectRoot $scriptDir

  $lastErr = ""
  foreach ($sc in $scopeCandidates) {
    foreach ($path in $pathCandidates) {
      foreach ($payload in $payloads) {
        try {
          $null = Invoke-VercelApiPatch -Path $path -Token $token -Scope $sc -Body $payload
          Write-Host "Deployment protection synced: Vercel Authentication set to OFF." -ForegroundColor Green
          return @{ Applied = $true; Status = "off"; Message = "patched" }
        } catch {
          $lastErr = Get-ApiErrorText $_
        }
      }
    }
  }

  Write-Host "Deployment protection sync skipped: API did not accept patch for this account/project." -ForegroundColor DarkYellow
  if (-not [string]::IsNullOrWhiteSpace($lastErr)) {
    Write-Host ("API response (short): {0}" -f $lastErr) -ForegroundColor DarkGray
  }
  Write-Host "Tip: in Vercel Dashboard -> Team/Project -> Deployment Protection, disable Vercel Authentication and redeploy." -ForegroundColor DarkYellow
  return @{ Applied = $false; Status = "unknown"; Message = $lastErr }
}

function Apply-ProjectRuntimeSettings([string]$ProjectName, [string]$Scope, [string]$TokenStorePath, [string]$Region, [int]$FunctionTimeoutSec = 60, [bool]$FluidEnabled = $true) {
  if ([string]::IsNullOrWhiteSpace($ProjectName)) { return $false }
  $token = Get-VercelApiToken -TokenStorePath $TokenStorePath
  if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "Runtime settings sync skipped: token not available for API." -ForegroundColor DarkYellow
    return $false
  }

  $projectId = Resolve-ProjectApiId -ProjectName $ProjectName -Scope $Scope -Token $token
  if ([string]::IsNullOrWhiteSpace($projectId)) {
    Write-Host "Runtime settings sync skipped: could not resolve project id via API." -ForegroundColor DarkYellow
    return $false
  }

  $regionCode = "iad1"
  if (-not [string]::IsNullOrWhiteSpace($Region)) { $regionCode = $Region.ToLowerInvariant() }
  $timeoutMax = if ($FluidEnabled) { 800 } else { 300 }
  $timeoutSec = [Math]::Max(30, [Math]::Min($timeoutMax, $FunctionTimeoutSec))
  $projectPathCandidates = @(
    "/v9/projects/$([uri]::EscapeDataString($projectId))",
    "/v9/projects/$([uri]::EscapeDataString($ProjectName))"
  )

  # Keep payloads aligned with Vercel project update schema variants.
  # Some accounts reject mixed top-level keys and return HTTP 400.
  $payloads = @(
    @{ resourceConfig = @{ fluid = $FluidEnabled; functionDefaultTimeout = $timeoutSec; functionDefaultRegions = @($regionCode) } },
    @{ resourceConfig = @{ fluid = $FluidEnabled; functionDefaultTimeout = $timeoutSec } },
    @{ resourceConfig = @{ fluid = $FluidEnabled; functionDefaultRegions = @($regionCode) } },
    @{ resourceConfig = @{ functionDefaultTimeout = $timeoutSec; functionDefaultRegions = @($regionCode) } },
    @{ resourceConfig = @{ functionDefaultTimeout = $timeoutSec } },
    @{ resourceConfig = @{ functionDefaultRegions = @($regionCode) } }
  )

  $scopeCandidates = Build-ScopeCandidates -Scope $Scope -Token $token -ProjectRoot $scriptDir

  $lastErr = ""
  foreach ($sc in $scopeCandidates) {
    foreach ($path in $projectPathCandidates) {
      foreach ($payload in $payloads) {
        try {
          $null = Invoke-VercelApiPatch -Path $path -Token $token -Scope $sc -Body $payload
          Write-Host ("Runtime settings synced by API: fluid={0}, timeout={1}s, region={2}" -f $(if ($FluidEnabled) { "on" } else { "off" }), $timeoutSec, $regionCode) -ForegroundColor Green
          return $true
        } catch {
          $lastErr = Get-ApiErrorText $_
        }
      }
    }
  }

  Write-Host "Runtime settings sync skipped: API did not accept project runtime patch for this account/project." -ForegroundColor DarkYellow
  if (-not [string]::IsNullOrWhiteSpace($lastErr)) {
    Write-Host ("API response (short): {0}" -f $lastErr) -ForegroundColor DarkGray
  }
  Write-Host "Tip: in Vercel Dashboard -> Project Settings -> Functions, set Fluid/Timeout/Region manually once, then redeploy." -ForegroundColor DarkYellow
  return $false
}

function Resolve-ProjectApiId([string]$ProjectName, [string]$Scope, [string]$Token) {
  $resp = Invoke-VercelApiGet -Path "/v9/projects?limit=100" -Token $Token -Scope $Scope
  if ($null -eq $resp -or $null -eq $resp.projects) { return "" }
  $hit = $resp.projects | Where-Object { $_.name -eq $ProjectName } | Select-Object -First 1
  if ($null -eq $hit) { return "" }
  return [string]$hit.id
}

function Get-LatestDeploymentApi([string]$ProjectId, [string]$Scope, [string]$Token) {
  if ([string]::IsNullOrWhiteSpace($ProjectId)) { return $null }
  $path = "/v6/deployments?projectId=$([uri]::EscapeDataString($ProjectId))&target=production&state=READY&limit=1"
  $resp = Invoke-VercelApiGet -Path $path -Token $Token -Scope $Scope
  if ($null -eq $resp -or $null -eq $resp.deployments -or $resp.deployments.Count -eq 0) { return $null }
  return $resp.deployments[0]
}

function Get-DeploymentEventsApi([string]$DeploymentId, [int]$Limit, [string]$Scope, [string]$Token) {
  if ([string]::IsNullOrWhiteSpace($DeploymentId)) { return @() }
  $path = "/v3/deployments/$DeploymentId/events?limit=$Limit"
  $resp = Invoke-VercelApiGet -Path $path -Token $Token -Scope $Scope
  if ($null -eq $resp) { return @() }
  if ($resp -is [System.Array]) { return @($resp) }
  if ($null -ne $resp.events) { return @($resp.events) }
  return @()
}

function Get-RecentLogsCli([string]$ProjectName, [string]$Scope, [int]$Minutes) {
  $Scope = Normalize-ScopeForCli -Scope $Scope
  $args = @("logs", $ProjectName, "--since", "${Minutes}m", "--limit", "200", "--json", "--no-color")
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  $res = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
  if ($res.ExitCode -ne 0 -or (($res.Output | Out-String) -match "(?i)does not support filtering|unknown or unexpected option|--json")) {
    # Fallback for CLI variants that don't support JSON/flag combinations.
    $fallbackArgs = @("logs", $ProjectName, "--since", "${Minutes}m", "--limit", "200", "--no-color")
    if (-not [string]::IsNullOrWhiteSpace($Scope)) { $fallbackArgs += @("--scope", $Scope) }
    $res = Invoke-NativeSafe -FilePath $VercelExe -Arguments $fallbackArgs
  }
  if ($res.ExitCode -ne 0) {
    return @{
      Ok = $false
      Lines = @($res.Output)
      ErrorText = (($res.Output | Out-String).Trim())
    }
  }
  return @{
    Ok = $true
    Lines = @($res.Output)
    ErrorText = ""
  }
}

function Unlink-LocalProjectIfMatches([string]$ProjectName, [string]$ProjectRoot) {
  try {
    $link = Get-LinkedProjectInfo -ProjectRoot $ProjectRoot
    if ($null -eq $link) { return }
    if ([string]::IsNullOrWhiteSpace($link.ProjectName)) { return }
    if ([string]$link.ProjectName -ne [string]$ProjectName) { return }
    $projJson = Join-Path $ProjectRoot ".vercel\\project.json"
    if (Test-Path $projJson) {
      Remove-Item -LiteralPath $projJson -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Local .vercel link cleaned (deleted project was linked here)." -ForegroundColor DarkYellow
  } catch {}
}

function Remove-SelectedProject([string]$ProjectName, [string]$Scope, [string]$TokenStorePath) {
  if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    throw "No selected project."
  }
  Write-Host ""
  Write-Host "DANGER: project deletion is permanent." -ForegroundColor Red
  Write-Host ("Target project: {0}" -f $ProjectName) -ForegroundColor Yellow
  if (-not [string]::IsNullOrWhiteSpace($Scope)) {
    Write-Host ("Scope: {0}" -f $Scope) -ForegroundColor Yellow
  }
  $c1 = Read-Default "Type DELETE to continue" ""
  if ($c1 -ne "DELETE") {
    Write-Host "Canceled." -ForegroundColor DarkYellow
    return $false
  }
  $c2 = Read-Required ("Type project name to confirm ({0})" -f $ProjectName)
  if ($c2 -ne $ProjectName) {
    Write-Host "Project name mismatch. Canceled." -ForegroundColor Red
    return $false
  }

  $token = Get-VercelApiToken -TokenStorePath $TokenStorePath
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "No API token available for project deletion."
  }

  $projectId = Resolve-ProjectApiId -ProjectName $ProjectName -Scope $Scope -Token $token
  $scopeCandidates = Build-ScopeCandidates -Scope $Scope -Token $token -ProjectRoot $scriptDir
  $pathCandidates = @()
  if (-not [string]::IsNullOrWhiteSpace($projectId)) {
    $pathCandidates += "/v9/projects/$([uri]::EscapeDataString($projectId))"
  }
  $pathCandidates += "/v9/projects/$([uri]::EscapeDataString($ProjectName))"
  $pathCandidates = @($pathCandidates | Select-Object -Unique)

  $lastErr = ""
  foreach ($sc in $scopeCandidates) {
    foreach ($p in $pathCandidates) {
      try {
        $null = Invoke-VercelApiDelete -Path $p -Token $token -Scope $sc
        Write-Host ("Project deleted: {0}" -f $ProjectName) -ForegroundColor Green
        Unlink-LocalProjectIfMatches -ProjectName $ProjectName -ProjectRoot $scriptDir
        return $true
      } catch {
        $lastErr = Get-ApiErrorText $_
      }
    }
  }
  throw ("Project delete failed. {0}" -f $lastErr)
}

function Convert-JsonLineSafe([string]$Line) {
  try {
    return ($Line | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Strip-AnsiCodes([string]$Text) {
  if ($null -eq $Text) { return "" }
  return ($Text -replace "`e\[[0-9;]*[A-Za-z]", "")
}

function Convert-CliTextLogLine([string]$Line) {
  $raw = Strip-AnsiCodes -Text $Line
  $t = $raw.Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { return $null }
  if ($t -match "^(Fetching|Displaying|Waiting|Ready|Visit|Tip:|Error:\s*The --follow flag does not support filtering)") { return $null }
  if ($t -match "^[-=]{3,}$") { return $null }

  $time = "-"
  if ($t -match "(?<tm>\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)") { $time = $Matches.tm }

  $status = ""
  if ($t -match "(?<!\d)([1-5][0-9]{2})(?!\d)") { $status = $Matches[1] }

  $method = ""
  if ($t -match "(?i)\b(GET|POST|HEAD|PUT|PATCH|DELETE|OPTIONS)\b") { $method = $Matches[1].ToUpperInvariant() }

  $path = ""
  if ($t -match "(\/[A-Za-z0-9_\-\.~\/%]+)") { $path = $Matches[1] }

  return [pscustomobject]@{
    time = $time
    text = $t
    status = $status
    method = $method
    path = $path
    duration = ""
    hint = Translate-LogHint -Text $t
  }
}

function Get-LogMessageText($obj) {
  if ($null -eq $obj) { return "" }
  $candidates = @("text", "message", "msg")
  foreach ($k in $candidates) {
    if ($obj.PSObject.Properties.Name -contains $k) {
      $v = [string]$obj.$k
      if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
  }
  return ""
}

function Get-LogStatusCode($obj) {
  if ($null -eq $obj) { return "" }
  if ($obj.PSObject.Properties.Name -contains "statusCode") {
    return [string]$obj.statusCode
  }
  $msg = Get-LogMessageText $obj
  if ($msg -match '\b([1-5][0-9]{2})\b') { return $Matches[1] }
  return ""
}

function Translate-LogHint([string]$Text) {
  if ($Text -match "(?i)upstream_timeout|Task timed out after|timeout") { return "timeout to upstream/function" }
  if ($Text -match "(?i)scope does not exist|invalid scope") { return "invalid scope/team slug" }
  if ($Text -match "(?i)MAX_INFLIGHT|service unavailable|503") { return "concurrency pressure (503)" }
  if ($Text -match "(?i)ENOTFOUND|EAI_AGAIN|dns|lookup") { return "dns/resolve issue" }
  if ($Text -match "(?i)ECONNRESET|socket hang up") { return "connection reset / upstream network issue" }
  if ($Text -match "(?i)\b404\b") { return "path mismatch (404)" }
  if ($Text -match "(?i)\b403\b") { return "auth/key mismatch (403)" }
  return "needs deeper inspection"
}

function Collapse-Whitespace([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  $t = $Text -replace "`r?`n", " "
  $t = $t -replace "\s{2,}", " "
  return $t.Trim()
}

function Parse-LogFieldsFromText([string]$Text) {
  $status = ""
  $method = ""
  $path = ""
  $duration = ""
  if ($Text -match "(?i)\bstatus(?:Code)?\b[:=\s'`"]+([1-5][0-9]{2})") { $status = $Matches[1] }
  if ($Text -match "(?i)\bmethod\b[:=\s'`"]+(GET|POST|HEAD|PUT|PATCH|DELETE|OPTIONS)") { $method = $Matches[1].ToUpperInvariant() }
  if ($Text -match "(?i)\b(?:rawPath|upstreamPath|path)\b[:=\s'`"]+([^,\s'`"}]+)") { $path = $Matches[1] }
  if ($Text -match "(?i)\bdurationMs\b[:=\s'`"]+([0-9]+)") { $duration = $Matches[1] }
  return @{
    Status = $status
    Method = $method
    Path = $path
    Duration = $duration
  }
}

function Get-LogColor([string]$Status, [string]$Text) {
  if (-not [string]::IsNullOrWhiteSpace($Status)) {
    if ($Status -match "^[45]") { return "Red" }
    if ($Status -match "^3") { return "Yellow" }
    if ($Status -match "^2") { return "Green" }
  }
  if ($Text -match "(?i)(error|fatal|timeout|upstream_|unhandled|503|504|502)") { return "Red" }
  if ($Text -match "(?i)(warn|warning|429|403|404)") { return "Yellow" }
  return "Gray"
}

function Write-CompactLogLine($Item) {
  $time = if ($null -ne $Item.time) { [string]$Item.time } else { "-" }
  $text = if ($null -ne $Item.text) { [string]$Item.text } else { "" }
  $hint = if ($null -ne $Item.hint) { [string]$Item.hint } else { Translate-LogHint -Text $text }
  $status = if ($null -ne $Item.status) { [string]$Item.status } else { "" }
  $method = if ($null -ne $Item.method) { [string]$Item.method } else { "" }
  $path = if ($null -ne $Item.path) { [string]$Item.path } else { "" }
  $duration = if ($null -ne $Item.duration) { [string]$Item.duration } else { "" }

  $parsed = Parse-LogFieldsFromText -Text $text
  if ([string]::IsNullOrWhiteSpace($status)) { $status = $parsed.Status }
  if ([string]::IsNullOrWhiteSpace($method)) { $method = $parsed.Method }
  if ([string]::IsNullOrWhiteSpace($path)) { $path = $parsed.Path }
  if ([string]::IsNullOrWhiteSpace($duration)) { $duration = $parsed.Duration }

  $compact = Collapse-Whitespace -Text $text
  if ($compact.Length -gt 160) { $compact = $compact.Substring(0, 160) + "..." }
  if ([string]::IsNullOrWhiteSpace($path)) { $path = "-" }
  if ([string]::IsNullOrWhiteSpace($method)) { $method = "-" }
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "-" }
  if ([string]::IsNullOrWhiteSpace($duration)) { $duration = "-" }

  $line = "[{0}] st={1} m={2} d={3}ms path={4} | {5} | {6}" -f $time, $status, $method, $duration, $path, $hint, $compact
  $color = Get-LogColor -Status $status -Text $text
  Write-Host $line -ForegroundColor $color
}

function Show-ProfessionalLogs([string]$ProjectName, [string]$Scope, [int]$Minutes, [string]$TokenStorePath) {
  Write-Step ("Recent logs (last {0} minutes)" -f $Minutes)
  $errors = @()
  $allLines = @()
  $anyActivity = $false
  $cutoff = (Get-Date).AddMinutes(-1 * $Minutes)

  $token = Get-VercelApiToken -TokenStorePath $TokenStorePath
  if (-not [string]::IsNullOrWhiteSpace($token)) {
    try {
      $projectId = Resolve-ProjectApiId -ProjectName $ProjectName -Scope $Scope -Token $token
      if (-not [string]::IsNullOrWhiteSpace($projectId)) {
        $dep = Get-LatestDeploymentApi -ProjectId $projectId -Scope $Scope -Token $token
        if ($null -ne $dep) {
          $events = Get-DeploymentEventsApi -DeploymentId $dep.uid -Limit 300 -Scope $Scope -Token $token
          foreach ($e in $events) {
            $txt = ""
            if ($null -ne $e.payload) { $txt = [string]$e.payload.text }
            if ([string]::IsNullOrWhiteSpace($txt)) { continue }
            $anyActivity = $true
            $when = $null
            if ($null -ne $e.createdAt) {
              try { $when = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$e.createdAt).LocalDateTime } catch {}
            }
            if ($null -ne $when -and $when -lt $cutoff) { continue }
            $parsed = Parse-LogFieldsFromText -Text $txt
            $item = [pscustomobject]@{
              time = if ($null -ne $when) { $when.ToString("HH:mm:ss") } else { "-" }
              text = $txt
              status = $parsed.Status
              method = $parsed.Method
              path = $parsed.Path
              duration = $parsed.Duration
              hint = Translate-LogHint -Text $txt
            }
            $allLines += $item
            if ($txt -match "(?i)(error|fatal|timeout|503|504|502|upstream_|unhandled)") {
              $errors += $item
            }
          }
        }
      }
    } catch {
      Write-Host "API log mode failed, trying CLI fallback..." -ForegroundColor DarkYellow
    }
  }

  if ($allLines.Count -eq 0) {
    $cli = Get-RecentLogsCli -ProjectName $ProjectName -Scope $Scope -Minutes $Minutes
    if ($cli.Ok) {
      foreach ($line in $cli.Lines) {
        $obj = Convert-JsonLineSafe -Line $line
        if ($null -ne $obj) {
          $t = Get-LogMessageText $obj
          if ([string]::IsNullOrWhiteSpace($t)) { continue }
          $anyActivity = $true
          $st = Get-LogStatusCode $obj
          $pp = ""
          if ($obj.PSObject.Properties.Name -contains "path") { $pp = [string]$obj.path }
          $item = [pscustomobject]@{
            time = if ($obj.PSObject.Properties.Name -contains "createdAt") { [string]$obj.createdAt } else { "-" }
            text = $t
            status = $st
            method = if ($obj.PSObject.Properties.Name -contains "method") { [string]$obj.method } else { "" }
            path = $pp
            duration = if ($obj.PSObject.Properties.Name -contains "durationMs") { [string]$obj.durationMs } else { "" }
            hint = Translate-LogHint -Text $t
          }
          $allLines += $item
          if ($t -match "(?i)(error|fatal|timeout|503|504|502|upstream_|unhandled)") {
            $errors += $item
          }
          continue
        }

        $parsedTextLine = Convert-CliTextLogLine -Line $line
        if ($null -ne $parsedTextLine) {
          $anyActivity = $true
          $allLines += $parsedTextLine
          if ([string]$parsedTextLine.text -match "(?i)(error|fatal|timeout|503|504|502|upstream_|unhandled)") {
            $errors += $parsedTextLine
          }
        }
      }
    } elseif (-not [string]::IsNullOrWhiteSpace($cli.ErrorText)) {
      Write-Host "CLI logs not available in this environment. Use option 12 (Live logs) while reproducing issue." -ForegroundColor DarkYellow
    }
  }

  if ($allLines.Count -gt 0) {
    Write-Host "Recent log lines (compact):" -ForegroundColor Cyan
    $allLines | Select-Object -First 150 | ForEach-Object { Write-CompactLogLine -Item $_ }
  } elseif ($anyActivity) {
    Write-Host "Traffic exists but readable log text was not returned in this window." -ForegroundColor DarkYellow
  } else {
    Write-Host "No log lines returned in selected window." -ForegroundColor Green
    Write-Host "Tip: reproduce issue, then run option 7/12 again." -ForegroundColor DarkYellow
  }

  if ($allLines.Count -gt 0) {
    $statusCounts = @{}
    foreach ($it in $allLines) {
      $st = [string]$it.status
      if ([string]::IsNullOrWhiteSpace($st)) { continue }
      if (-not $statusCounts.ContainsKey($st)) { $statusCounts[$st] = 0 }
      $statusCounts[$st]++
    }
    if ($statusCounts.Count -gt 0) {
      Write-Host "Status summary:" -ForegroundColor Cyan
      $statusCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
        Write-Host (" - {0}: {1}" -f $_.Name, $_.Value)
      }
    }
  }

  return $errors
}

function Start-LiveLogsTranslated([string]$ProjectName, [string]$Scope, [string]$TokenStorePath) {
  Write-Step "Live logs"
  Write-Host "Compact mode: one-line summary per log entry" -ForegroundColor Cyan
  Write-Host "Tip: if nothing appears, generate traffic first (client ping/test)." -ForegroundColor DarkYellow
  Write-Host "Press Q to return to main menu." -ForegroundColor DarkYellow
  $Scope = Normalize-ScopeForCli -Scope $Scope
  $args = @("logs", $ProjectName, "--follow", "--no-color")
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  $liveToken = Get-VercelApiToken -TokenStorePath $TokenStorePath
  if (-not [string]::IsNullOrWhiteSpace($liveToken)) { $args += @("--token", $liveToken) }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $VercelExe
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  # Windows PowerShell/.NET Framework compatibility:
  # ProcessStartInfo.ArgumentList can be null/unsupported, so build Arguments string.
  $quotedArgs = @()
  foreach ($a in $args) {
    $s = [string]$a
    if ($s -match '\s') {
      $quotedArgs += ('"' + ($s -replace '"', '\"') + '"')
    } else {
      $quotedArgs += $s
    }
  }
  $psi.Arguments = ($quotedArgs -join " ")

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $proc.EnableRaisingEvents = $true

  $queue = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
  $seen = @{}
  $rawErr = New-Object System.Collections.ArrayList
  $handlerOut = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs -and -not [string]::IsNullOrWhiteSpace($eventArgs.Data)) {
      [void]$queue.Add($eventArgs.Data)
    }
  }
  $handlerErr = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs -and -not [string]::IsNullOrWhiteSpace($eventArgs.Data)) {
      [void]$queue.Add($eventArgs.Data)
    }
  }

  try {
    [void]$proc.Start()
    $proc.add_OutputDataReceived($handlerOut)
    $proc.add_ErrorDataReceived($handlerErr)
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
  } catch {
    throw ("Failed to start live log stream: {0}" -f $_.Exception.Message)
  }

  $lastHeartbeat = Get-Date
  try {
    while ($true) {
      try {
        if ([Console]::KeyAvailable) {
          $key = [Console]::ReadKey($true)
          if ($key.Key -eq [ConsoleKey]::Q) { break }
        }
      } catch {}

      $printed = 0
      while ($queue.Count -gt 0) {
        try {
          $line = [string]$queue[0]
          $queue.RemoveAt(0)

          $obj = Convert-JsonLineSafe -Line $line
          if ($null -ne $obj) {
            $txt = Get-LogMessageText $obj
            if ([string]::IsNullOrWhiteSpace($txt)) { continue }
            $sig = ("json|{0}|{1}" -f [string]$obj.createdAt, $txt)
            if ($seen.ContainsKey($sig)) { continue }
            $seen[$sig] = 1
            $item = [pscustomobject]@{
              time = if ($obj.PSObject.Properties.Name -contains "createdAt") { [string]$obj.createdAt } else { "-" }
              text = $txt
              status = Get-LogStatusCode $obj
              method = if ($obj.PSObject.Properties.Name -contains "method") { [string]$obj.method } else { "" }
              path = if ($obj.PSObject.Properties.Name -contains "path") { [string]$obj.path } else { "" }
              duration = if ($obj.PSObject.Properties.Name -contains "durationMs") { [string]$obj.durationMs } else { "" }
              hint = Translate-LogHint -Text $txt
            }
            Write-CompactLogLine -Item $item
            $printed++
            continue
          }

          $itemText = Convert-CliTextLogLine -Line $line
          if ($null -eq $itemText) {
            if ($line -match "(?i)\berror\b|\bnot authorized\b|\bforbidden\b|\binvalid\b|\bfailed\b") {
              [void]$rawErr.Add($line)
              Write-Host ("[live-error] {0}" -f $line) -ForegroundColor Red
            }
            continue
          }
          $sig2 = ("txt|{0}|{1}" -f $itemText.time, $itemText.text)
          if ($seen.ContainsKey($sig2)) { continue }
          $seen[$sig2] = 1
          Write-CompactLogLine -Item $itemText
          $printed++
        } catch {
          $em = ""
          try { $em = $_.Exception.Message } catch { $em = "unknown parse error" }
          if (-not [string]::IsNullOrWhiteSpace($em)) {
            [void]$rawErr.Add($em)
            Write-Host ("[live-parse-error] {0}" -f $em) -ForegroundColor DarkYellow
          }
          continue
        }
      }

      $now = Get-Date
      if ($printed -eq 0 -and (($now - $lastHeartbeat).TotalSeconds -ge 8)) {
        Write-Host "[live] waiting for new logs..." -ForegroundColor DarkGray
        $lastHeartbeat = $now
      }
      if ($printed -gt 0) {
        $lastHeartbeat = $now
      }

      if ($proc.HasExited -and $queue.Count -eq 0) {
        if ($proc.ExitCode -eq 0) {
          Write-Host ("[live] stream ended (exit={0}). press Enter to continue." -f $proc.ExitCode) -ForegroundColor DarkYellow
        } else {
          Write-Host ("[live] stream ended with error (exit={0})." -f $proc.ExitCode) -ForegroundColor Red
          if ($rawErr.Count -gt 0) {
            Write-Host ("hint: {0}" -f [string]$rawErr[$rawErr.Count - 1]) -ForegroundColor DarkYellow
          } else {
            Write-Host "hint: check token/scope/project access, then retry." -ForegroundColor DarkYellow
          }
          Write-Host "press Enter to continue." -ForegroundColor DarkYellow
        }
        break
      }
      Start-Sleep -Milliseconds 400
    }
  } catch {
    $m = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($m)) { $m = "unknown runtime error" }
    Write-Host ("[live] stream runtime error: {0}" -f $m) -ForegroundColor Red
    Write-Host "hint: retry option 12, and ensure token/scope/project are valid." -ForegroundColor DarkYellow
  } finally {
    try {
      if (-not $proc.HasExited) { $proc.Kill() }
    } catch {}
    try { $proc.remove_OutputDataReceived($handlerOut) } catch {}
    try { $proc.remove_ErrorDataReceived($handlerErr) } catch {}
    $proc.Dispose()
  }
}

function Get-IncidentAnalysis([string[]]$LogTexts) {
  $joined = ($LogTexts -join "`n")
  $issues = @()
  $actions = @()

  if ($joined -match "(?i)scope does not exist|invalid scope|team slug") {
    $issues += "Installer/CLI scope is invalid."
    $actions += "Set scope to a valid team slug (or empty for personal account)."
  }
  if ($joined -match "(?i)Task timed out after|upstream_timeout|504") {
    $issues += "Requests are timing out before completion."
    $actions += "Increase UPSTREAM_TIMEOUT_MS (e.g. 60000) and keep maxDuration at 60."
    $actions += "Reduce per-connection speed or concurrency spikes to shorten request lifetime."
  }
  if ($joined -match "(?i)503|MAX_INFLIGHT|service unavailable") {
    $issues += "Concurrency ceiling is being hit."
    $actions += "Increase MAX_INFLIGHT in steps (e.g. +64) and retest."
  }
  if ($joined -match "(?i)ENOTFOUND|EAI_AGAIN|ECONNRESET|dns|lookup") {
    $issues += "Upstream DNS/connectivity instability detected."
    $actions += "Set UPSTREAM_DNS_ORDER=ipv4first and verify upstream host/IP availability."
  }
  if ($joined -match "(?i)\b404\b") {
    $issues += "Relay path mismatch appears in traffic."
    $actions += "Verify RELAY_PATH in project env exactly matches client path."
  }
  if ($joined -match "(?i)\b403\b") {
    $issues += "Authorization mismatch appears in requests."
    $actions += "Check x-relay-key header and auth setup on both client and relay."
  }

  if ($issues.Count -eq 0) {
    $issues += "No clear failure signature found in sampled logs."
    $actions += "If you still have issue, reproduce traffic first, then run option 7 with a larger minutes window (e.g. 30)."
    $actions += "Status 400 on probe path is usually normal (probe payload is not full client protocol)."
  }

  return @{
    Issues = @($issues | Select-Object -Unique)
    Actions = @($actions | Select-Object -Unique)
  }
}

function Get-HttpStatusCodeSafe([string]$Url, [string]$Method = "GET", [int]$TimeoutSec = 20) {
  try {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AllowAutoRedirect = $true
    $resp = [System.Net.HttpWebResponse]$req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return $code
  } catch [System.Net.WebException] {
    if ($_.Exception.Response -ne $null) {
      try {
        return [int]([System.Net.HttpWebResponse]$_.Exception.Response).StatusCode
      } catch {
        return 0
      }
    }
    return 0
  } catch {
    return 0
  }
}

function Run-HealthAndSmokeChecks([string]$ProjectName, [string]$RelayPath) {
  $domain = "https://$ProjectName.vercel.app"
  $rp = if ($RelayPath.StartsWith("/")) { $RelayPath } else { "/$RelayPath" }

  Write-Step "Health Check"
  try {
    $rootSw = [System.Diagnostics.Stopwatch]::StartNew()
    $rootStatus = Get-HttpStatusCodeSafe -Url "$domain/" -Method "GET" -TimeoutSec 20
    $rootSw.Stop()
    if ($rootStatus -gt 0) {
      Write-Host ("Root: {0} ({1} ms)" -f $rootStatus, $rootSw.ElapsedMilliseconds) -ForegroundColor Green
    } else {
      Write-Host "Root: no response" -ForegroundColor Yellow
    }
  } catch {
    Write-Host ("Root failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
  }
  try {
    $apiSw = [System.Diagnostics.Stopwatch]::StartNew()
    $apiStatus = Get-HttpStatusCodeSafe -Url "$domain$rp/test" -Method "GET" -TimeoutSec 20
    $apiSw.Stop()
    if ($apiStatus -gt 0) {
      Write-Host ("API: {0} ({1} ms)" -f $apiStatus, $apiSw.ElapsedMilliseconds) -ForegroundColor Green
      if ($apiStatus -eq 400) {
        Write-Host "Note: API=400 in this check is usually normal. This probe is raw and not a full client tunnel handshake." -ForegroundColor DarkYellow
      }
    } else {
      Write-Host "API: no response" -ForegroundColor Yellow
    }
  } catch {
    Write-Host ("API failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
  }

  Write-Step "Smoke Tests"
  $st1 = Get-HttpStatusCodeSafe -Url "$domain/not-a-relay-path" -Method "GET" -TimeoutSec 20
  if ($st1 -eq 404) {
    Write-Host ("[PASS] Wrong path check | expected 404 | got {0}" -f $st1) -ForegroundColor Green
  } else {
    Write-Host ("[WARN] Wrong path check | expected 404 | got {0}" -f $st1) -ForegroundColor Yellow
  }

  $st2 = Get-HttpStatusCodeSafe -Url "$domain$rp/test" -Method "PUT" -TimeoutSec 20
  if ($st2 -eq 405) {
    Write-Host ("[PASS] Wrong method check | expected 405 | got {0}" -f $st2) -ForegroundColor Green
  } else {
    Write-Host ("[WARN] Wrong method check | expected 405 | got {0}" -f $st2) -ForegroundColor Yellow
  }

  $st3 = Get-HttpStatusCodeSafe -Url "$domain$rp/$([guid]::NewGuid().ToString())/0" -Method "GET" -TimeoutSec 20
  if ($st3 -ne 404 -and $st3 -gt 0) {
    Write-Host ("[PASS] Valid relay path check | expected non-404 | got {0}" -f $st3) -ForegroundColor Green
  } else {
    Write-Host ("[FAIL] Valid relay path check | expected non-404 | got {0}" -f $st3) -ForegroundColor Red
  }
  if ($st3 -eq 400) {
    Write-Host "Explanation: path is reachable. HTTP 400 here usually means probe payload is not a real client protocol frame." -ForegroundColor DarkYellow
  } elseif ($st3 -eq 404) {
    Write-Host "Action: likely RELAY_PATH mismatch. Open your foreign server inbound and copy exact Path (with leading '/')." -ForegroundColor Red
  } elseif ($st3 -ge 500) {
    Write-Host "Action: 5xx means upstream/runtime pressure. Reduce load or increase timeout/capacity." -ForegroundColor Red
  } elseif ($st3 -ge 200 -and $st3 -lt 400) {
    Write-Host "Explanation: relay path answered normally for this probe." -ForegroundColor Green
  }
}

function Run-LoadTestLite([string]$ProjectName, [string]$RelayPath) {
  $domain = "https://$ProjectName.vercel.app"
  $rp = if ($RelayPath.StartsWith("/")) { $RelayPath } else { "/$RelayPath" }
  $requests = [int](Read-Default "Total requests" "40")
  $parallel = [int](Read-Default "Parallel jobs" "8")
  if ($requests -lt 1) { $requests = 40 }
  if ($parallel -lt 1) { $parallel = 8 }

  Write-Step ("Load-test lite: {0} req, {1} parallel" -f $requests, $parallel)
  $activeJobs = New-Object System.Collections.ArrayList
  $done = 0
  $ok = 0
  $fail = 0
  $swAll = [System.Diagnostics.Stopwatch]::StartNew()

  for ($i = 0; $i -lt $requests; $i++) {
    while ((@($activeJobs | Where-Object { $_.State -eq "Running" })).Count -ge $parallel) {
      Start-Sleep -Milliseconds 100
      $finished = @($activeJobs | Where-Object { $_.State -ne "Running" })
      foreach ($j in $finished) {
        $result = @(Receive-Job -Job $j -ErrorAction SilentlyContinue)
        if ($result -contains 1) { $ok++ } else { $fail++ }
        Remove-Job $j -Force -ErrorAction SilentlyContinue
        [void]$activeJobs.Remove($j)
        $done++
      }
    }

    $url = "$domain$rp/$([guid]::NewGuid().ToString())/0"
    $job = Start-Job -ScriptBlock {
      param($u)
      try {
        $req = [System.Net.HttpWebRequest]::Create($u)
        $req.Method = "GET"
        $req.Timeout = 20000
        $req.ReadWriteTimeout = 20000
        $req.AllowAutoRedirect = $true
        $resp = [System.Net.HttpWebResponse]$req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        if ($code -gt 0 -and $code -lt 500) { return 1 }
        return 0
      } catch [System.Net.WebException] {
        if ($_.Exception.Response -ne $null) {
          try {
            $code = [int]([System.Net.HttpWebResponse]$_.Exception.Response).StatusCode
            if ($code -gt 0 -and $code -lt 500) { return 1 }
          } catch {}
        }
        return 0
      } catch {
        return 0
      }
    } -ArgumentList $url
    [void]$activeJobs.Add($job)
  }

  while ($activeJobs.Count -gt 0) {
    Start-Sleep -Milliseconds 100
    $finished = @($activeJobs | Where-Object { $_.State -ne "Running" })
    foreach ($j in $finished) {
      $result = @(Receive-Job -Job $j -ErrorAction SilentlyContinue)
      if ($result -contains 1) { $ok++ } else { $fail++ }
      Remove-Job $j -Force -ErrorAction SilentlyContinue
      [void]$activeJobs.Remove($j)
      $done++
    }
  }
  $swAll.Stop()
  Write-Host ("Load test done | ok={0} fail={1} total={2} elapsedMs={3}" -f $ok, $fail, $done, $swAll.ElapsedMilliseconds) -ForegroundColor Cyan
  if ($fail -eq 0) {
    Write-Host "Result: healthy under this light load." -ForegroundColor Green
  } else {
    Write-Host "Result: some requests failed (usually timeout/network/5xx under load)." -ForegroundColor Yellow
  }
}

function Get-EnvMapFromApi([string]$ProjectName, [string]$Scope, [string]$TokenStorePath) {
  $cliMap = Get-EnvMapFromCliPull -ProjectName $ProjectName -Scope $Scope -TokenStorePath $TokenStorePath
  if ($cliMap.Count -gt 0) { return $cliMap }

  $token = Get-VercelApiToken -TokenStorePath $TokenStorePath
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "No token available for API env read."
  }
  # Ask API for decrypted values when possible (depends on token/permissions/type).
  $path = "/v10/projects/$([uri]::EscapeDataString($ProjectName))/env?target=production&limit=200&decrypt=true"
  $resp = Invoke-VercelApiGet -Path $path -Token $token -Scope $Scope
  $map = @{}
  if ($null -ne $resp -and $null -ne $resp.envs) {
    foreach ($e in $resp.envs) {
      $k = [string]$e.key
      if (-not [string]::IsNullOrWhiteSpace($k)) {
        $val = ""
        try {
          if ($e.PSObject.Properties.Name -contains "decrypted") {
            $dv = [string]$e.decrypted
            if (-not [string]::IsNullOrWhiteSpace($dv)) { $val = $dv }
          }
          if ([string]::IsNullOrWhiteSpace($val) -and $e.PSObject.Properties.Name -contains "decryptedValue") {
            $dv2 = [string]$e.decryptedValue
            if (-not [string]::IsNullOrWhiteSpace($dv2)) { $val = $dv2 }
          }
          if ([string]::IsNullOrWhiteSpace($val)) { $val = [string]$e.value }
        } catch {}
        $map[$k] = @{
          exists = $true
          value = $val
          source = "api"
        }
      }
    }
  }
  return $map
}

function Run-EnvDriftDetector([string]$ProjectName, [string]$Scope, [string]$TokenStorePath) {
  Write-Step "ENV drift detector"
  $profiles = @{
    eco = @{
      "UPSTREAM_TIMEOUT_MS" = "50000"
      "MAX_INFLIGHT" = "128"
      "MAX_UP_BPS" = "2621440"
      "MAX_DOWN_BPS" = "2621440"
      "SUCCESS_LOG_SAMPLE_RATE" = "0"
      "SUCCESS_LOG_MIN_DURATION_MS" = "3000"
      "ERROR_LOG_MIN_INTERVAL_MS" = "5000"
    }
    balanced = @{
      "UPSTREAM_TIMEOUT_MS" = "60000"
      "MAX_INFLIGHT" = "256"
      "MAX_UP_BPS" = "5242880"
      "MAX_DOWN_BPS" = "5242880"
      "SUCCESS_LOG_SAMPLE_RATE" = "0"
      "SUCCESS_LOG_MIN_DURATION_MS" = "3000"
      "ERROR_LOG_MIN_INTERVAL_MS" = "5000"
    }
    performance = @{
      "UPSTREAM_TIMEOUT_MS" = "60000"
      "MAX_INFLIGHT" = "512"
      "MAX_UP_BPS" = "10485760"
      "MAX_DOWN_BPS" = "10485760"
      "SUCCESS_LOG_SAMPLE_RATE" = "0"
      "SUCCESS_LOG_MIN_DURATION_MS" = "3000"
      "ERROR_LOG_MIN_INTERVAL_MS" = "5000"
    }
  }

  Write-Host "Profiles: eco | balanced | performance" -ForegroundColor Cyan
  Write-Host "Profile here means: expected target values for this project's behavior." -ForegroundColor DarkGray
  $p = Read-Default "Select baseline profile" "balanced"
  if (-not $profiles.ContainsKey($p)) { $p = "balanced" }
  $baseline = $profiles[$p]

  $current = Get-EnvMapFromApi -ProjectName $ProjectName -Scope $Scope -TokenStorePath $TokenStorePath
  Write-Host ("Baseline profile: {0}" -f $p) -ForegroundColor Yellow
  Write-Host "This check verifies presence for all keys and value drift when value is readable from API." -ForegroundColor DarkGray
  $ok = 0
  $drift = 0
  $missing = 0
  $unknown = 0
  foreach ($k in $baseline.Keys) {
    if ($current.ContainsKey($k)) {
      $entry = $current[$k]
      $currVal = ""
      if ($null -ne $entry -and $entry.ContainsKey("value")) { $currVal = [string]$entry.value }
      if (Test-IsMaskedOrEncryptedEnvValue -Value $currVal) {
        Write-Host ("[PRESENT] {0} exists (value hidden/sensitive in API, drift not verifiable). expected={1}" -f $k, $baseline[$k]) -ForegroundColor DarkYellow
        $unknown++
      } elseif ($currVal -eq [string]$baseline[$k]) {
        Write-Host ("[OK] {0} = {1}" -f $k, $currVal) -ForegroundColor Green
        $ok++
      } else {
        Write-Host ("[DRIFT] {0} current={1} | expected={2}" -f $k, $currVal, $baseline[$k]) -ForegroundColor Yellow
        $drift++
      }
    } else {
      Write-Host ("[MISSING] {0} (recommended: {1})" -f $k, $baseline[$k]) -ForegroundColor Red
      $missing++
    }
  }
  Write-Host ""
  Write-Host ("Summary: OK={0} DRIFT={1} MISSING={2} UNKNOWN={3}" -f $ok, $drift, $missing, $unknown) -ForegroundColor Cyan
  if ($missing -gt 0 -or $drift -gt 0) {
    Write-Host "Tip: use option 3 (Update production env vars) to align values with your selected profile." -ForegroundColor Yellow
  }
}

function Run-ProfileBenchmark([string]$ProjectName, [string]$RelayPath, [string]$Scope, [string]$TokenStorePath) {
  Write-Step "Profile benchmark runner"
  Write-Host "This runner executes health + smoke + load-lite + log analysis." -ForegroundColor Cyan
  Write-Host ("Using relay path: {0}" -f $RelayPath) -ForegroundColor DarkGray
  Write-Host "IMPORTANT: this must be EXACTLY your foreign server inbound Path (for example: /api or /freedom)." -ForegroundColor Yellow
  Run-HealthAndSmokeChecks -ProjectName $ProjectName -RelayPath $RelayPath
  $runLoad = Read-Default "Run load-test lite now? (y/N)" "n"
  if ($runLoad.ToLowerInvariant() -eq "y") {
    Run-LoadTestLite -ProjectName $ProjectName -RelayPath $RelayPath
  }
  $minutes = [int](Read-Default "Minutes window for log analysis" "5")
  $errs = Show-ProfessionalLogs -ProjectName $ProjectName -Scope $Scope -Minutes $minutes -TokenStorePath $TokenStorePath

  $txts = @()
  foreach ($e in $errs) { $txts += [string]$e.text }
  $incident = Get-IncidentAnalysis -LogTexts $txts
  Write-Host ""
  Write-Host "Incident analyzer report" -ForegroundColor Yellow
  Write-Host "What broke:" -ForegroundColor Red
  foreach ($i in $incident.Issues) { Write-Host " - $i" -ForegroundColor Red }
  Write-Host "What to change:" -ForegroundColor Green
  foreach ($a in $incident.Actions) { Write-Host " - $a" -ForegroundColor Green }
}

function Set-VercelFunctionRegion([string]$Region) {
  $path = Join-Path $scriptDir "vercel.json"
  if (-not (Test-Path $path)) { throw "vercel.json not found." }
  $raw = Get-Content $path -Raw
  $json = $raw | ConvertFrom-Json
  if ($null -eq $json.functions) { throw "vercel.json has no functions block." }
  if ($null -eq $json.functions.'api/index.js') { throw "vercel.json has no functions['api/index.js'] block." }
  $json.functions.'api/index.js'.regions = @($Region)
  $updated = $json | ConvertTo-Json -Depth 20
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $updated, $utf8NoBom)
  return @{
    Modified = $true
    ConfigPath = $path
    OriginalContent = $raw
  }
}

function Run-RegionABCompare([string]$ProjectName, [string]$Scope, [string]$RelayPath) {
  Write-Step "Region A/B deploy compare"
  Write-Host "This test deploys twice (Region A and Region B), then probes the same relay path." -ForegroundColor DarkGray
  Write-Host "How to read this table:" -ForegroundColor DarkGray
  Write-Host " - Lower DurationMs = usually faster region for your path." -ForegroundColor DarkGray
  Write-Host " - Status 400 on probe is usually normal (raw probe, not full client frame)." -ForegroundColor DarkGray
  Write-Host " - Status 404 means relay path mismatch." -ForegroundColor DarkGray
  Write-Host " - Status >=500 means upstream/runtime pressure or timeout." -ForegroundColor DarkGray
  $rp = Normalize-PathLike -PathValue $RelayPath
  $a = Read-Default "Region A" "iad1"
  $b = Read-Default "Region B" "fra1"
  $results = @()
  foreach ($r in @($a, $b)) {
    Write-Host ("Deploying with regions=['{0}'] ..." -f $r) -ForegroundColor Yellow
    try {
      $deployInfo = Deploy-Production -Scope $Scope -Region $r -Runtime "node"
      $url = "https://$ProjectName.vercel.app$rp/$([guid]::NewGuid().ToString())/0"
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $status = Get-HttpStatusCodeSafe -Url $url -Method "GET" -TimeoutSec 25
      $sw.Stop()
      $results += [pscustomobject]@{
        Region = $r
        Status = $status
        DurationMs = $sw.ElapsedMilliseconds
        Alias = $deployInfo.Alias
      }
    } catch {
      $results += [pscustomobject]@{
        Region = $r
        Status = -1
        DurationMs = -1
        Alias = "deploy_failed"
      }
      Write-Host ("Region {0} failed: {1}" -f $r, $_.Exception.Message) -ForegroundColor Red
    }
  }

  Write-Host ""
  Write-Host "A/B compare result:" -ForegroundColor Cyan
  $results | Format-Table -AutoSize | Out-Host
  $valid = @($results | Where-Object { $_.Status -gt 0 -and $_.DurationMs -ge 0 })
  if ($valid.Count -ge 2) {
    $best = $valid | Sort-Object DurationMs | Select-Object -First 1
    Write-Host ("Best region by probe latency: {0} ({1} ms, status {2})" -f $best.Region, $best.DurationMs, $best.Status) -ForegroundColor Green
  } elseif ($valid.Count -eq 1) {
    Write-Host ("Only one region returned a valid probe result: {0}" -f $valid[0].Region) -ForegroundColor Yellow
  } else {
    Write-Host "No valid probe result from either region. Check deploy output and try again." -ForegroundColor Red
  }
}

function Show-ManageMenu($selectedProjectName, $scope) {
  Write-Banner
  Write-PreflightNotice
  Write-Host ""
  Write-Host "Current target project:" -ForegroundColor Cyan
  if ($selectedProjectName) { Write-Host "Project: $selectedProjectName" } else { Write-Host "Project: (not selected)" }
  if ($scope) { Write-Host "Scope:   $scope" } else { Write-Host "Scope:   (default)" }
  Write-Host ""
  Write-Host "[1] Select project from Vercel list"
  Write-Host "[2] Redeploy selected project"
  Write-Host "[3] Update production env vars (selected project)"
  Write-Host "[4] List recent deployments (selected project)"
  Write-Host "[5] Deploy as NEW project"
  Write-Host "[6] Run health + smoke checks"
  Write-Host "[7] Show professional logs (translated/compact)"
  Write-Host "[8] Run load-test lite"
  Write-Host "[9] ENV drift detector"
  Write-Host "[10] Profile benchmark runner"
  Write-Host "[11] Live logs (translated/compact, press Q to stop)"
  Write-Host "[12] View deployment ENV config (full)"
  Write-Host "[13] Delete selected project (DANGER)"
  Write-Host "[14] Exit"
  return (Read-Default "Choose action" "1")
}

function Run-ManagementLoop([string]$InitialScope) {
  $link = Get-LinkedProjectInfo -ProjectRoot $scriptDir
  $scope = if (-not [string]::IsNullOrWhiteSpace($link.Scope)) { $link.Scope } else { $InitialScope }
  $selectedProjectName = $link.ProjectName

  if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
    $firstChoice = Select-ProjectOrNewForFirstRun -Scope $scope
    if ($firstChoice.Mode -eq "existing") {
      $selectedProjectName = $firstChoice.ProjectName
      Ensure-LinkedToProject -ProjectName $selectedProjectName -Scope $scope
      Write-Host "Selected project: $selectedProjectName" -ForegroundColor Green
    } else {
      Run-NewDeploymentFlow -DefaultScope $scope
      $link = Get-LinkedProjectInfo -ProjectRoot $scriptDir
      if ($link.ProjectName) { $selectedProjectName = $link.ProjectName }
      if ($link.Scope) { $scope = $link.Scope }
    }
  }

  while ($true) {
    if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
      Write-Host "No target project selected yet." -ForegroundColor DarkYellow
    }

    $choice = Show-ManageMenu -selectedProjectName $selectedProjectName -scope $scope
    if ($choice -eq "14") {
      Write-Host "Exit."
      break
    }

    try {
      switch ($choice) {
        "1" {
          $selected = Select-ProjectFromList -Scope $scope
          if ($null -ne $selected) {
            $selectedProjectName = $selected.Name
            Write-Host "Selected project: $selectedProjectName" -ForegroundColor Green
            Ensure-LinkedToProject -ProjectName $selectedProjectName -Scope $scope
          }
        }
        "2" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          Ensure-LinkedToProject -ProjectName $selectedProjectName -Scope $scope
          $deployInfo = Deploy-Production -Scope $scope -Runtime "node"
          Show-DeploySummary $deployInfo
          Write-Host "Done."
        }
        "3" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          Ensure-LinkedToProject -ProjectName $selectedProjectName -Scope $scope
          Run-UpdateEnvFlow -Scope $scope
          Write-Host "Done."
        }
        "4" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          Show-DeploymentList -ProjectName $selectedProjectName -Scope $scope
          Write-Host "Done."
        }
        "5" {
          Run-NewDeploymentFlow -DefaultScope $scope
          $newLink = Get-LinkedProjectInfo -ProjectRoot $scriptDir
          if ($newLink.ProjectName) { $selectedProjectName = $newLink.ProjectName }
          if ($newLink.Scope) { $scope = $newLink.Scope }
        }
        "6" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          $rp = Read-Default "Relay path for checks" "/api"
          Run-HealthAndSmokeChecks -ProjectName $selectedProjectName -RelayPath $rp
        }
        "7" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          $mins = [int](Read-Default "Minutes window" "5")
          $errs = Show-ProfessionalLogs -ProjectName $selectedProjectName -Scope $scope -Minutes $mins -TokenStorePath $tokenStorePath
          $logTexts = @()
          foreach ($e in $errs) { $logTexts += [string]$e.text }
          $inc = Get-IncidentAnalysis -LogTexts $logTexts
          Write-Host ""
          Write-Host "Quick incident report (simple):" -ForegroundColor Yellow
          Write-Host "Main issue:" -ForegroundColor Red
          foreach ($i in $inc.Issues) { Write-Host " - $i" -ForegroundColor Red }
          Write-Host "Suggested fix:" -ForegroundColor Green
          foreach ($a in $inc.Actions) { Write-Host " - $a" -ForegroundColor Green }
        }
        "8" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          Write-Host "Enter your EXACT inbound Path from foreign server (must start with '/')." -ForegroundColor Yellow
          $rp = Normalize-PathLike -PathValue (Read-Required "Relay path for load test (example: /api or /freedom)")
          Run-LoadTestLite -ProjectName $selectedProjectName -RelayPath $rp
        }
        "9" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          Run-EnvDriftDetector -ProjectName $selectedProjectName -Scope $scope -TokenStorePath $tokenStorePath
        }
        "10" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          Write-Host "IMPORTANT: enter your EXACT foreign server inbound Path (with leading '/')." -ForegroundColor Yellow
          $rp = Normalize-PathLike -PathValue (Read-Required "Relay path for benchmark (example: /api or /freedom)")
          Run-ProfileBenchmark -ProjectName $selectedProjectName -RelayPath $rp -Scope $scope -TokenStorePath $tokenStorePath
        }
        "11" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          Start-LiveLogsTranslated -ProjectName $selectedProjectName -Scope $scope -TokenStorePath $tokenStorePath
        }
        "12" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          Show-DeploymentEnvConfig -ProjectName $selectedProjectName -Scope $scope -TokenStorePath $tokenStorePath
        }
        "13" {
          if ([string]::IsNullOrWhiteSpace($selectedProjectName)) {
            Write-Host "Select a project first (option 1)." -ForegroundColor Red
            break
          }
          $deleted = Remove-SelectedProject -ProjectName $selectedProjectName -Scope $scope -TokenStorePath $tokenStorePath
          if ($deleted) {
            $selectedProjectName = ""
            Write-Host ""
            Write-Host "Project removed. Select another project (option 1) or deploy a new one (option 5)." -ForegroundColor Yellow
          }
        }
        default {
          Write-Host "Invalid option." -ForegroundColor Red
        }
      }
    } catch {
      Write-Host ""
      Write-Host "Action failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Read-Host "Press Enter to return to main menu (or Ctrl+C to exit)"
  }
}

Write-Banner
Write-PreflightNotice
Read-Host "Press Enter to continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir
$tokenStorePath = Get-TokenStorePath -ProjectRoot $scriptDir
$scopeStorePath = Get-ScopeStorePath -ProjectRoot $scriptDir

try {
  if (-not (Test-Path (Join-Path $scriptDir "api\index.js"))) {
    throw "api/index.js not found. Run this script from project root."
  }
  if (-not (Test-Path (Join-Path $scriptDir "vercel.json"))) {
    throw "vercel.json not found. Run this script from project root."
  }

  Ensure-NodeAndNpm
  Ensure-VercelCli
  Ensure-VercelLogin -OutputDir $scriptDir -TokenStorePath $tokenStorePath
  $sessionScope = Resolve-SessionScope -ScopeStorePath $scopeStorePath
  Write-Host "Deploy path: $scriptDir" -ForegroundColor DarkGray

  Run-ManagementLoop -InitialScope $sessionScope
} catch {
  Write-Host ""
  Write-Host ("Startup failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
  Write-Host "Tip: if token mode fails, generate a fresh Full Access token and retry." -ForegroundColor DarkYellow
  Read-Host "Press Enter to exit"
  exit 1
}
