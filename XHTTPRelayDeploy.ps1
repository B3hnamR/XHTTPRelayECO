<#
    XHTTPRelayDeploy.ps1
    --------------------
    Windows menu-based deployer for an authorized HTTP streaming relay on Vercel.

    Scope / safety:
      * This tool only manages Vercel scopes the supplied API token can access.
      * It performs NO scanning, exploitation, credential harvesting, or any action
        against third-party systems. It uses the official Vercel REST API only.
      * The relay it deploys is a transparent reverse proxy to a backend YOU own
        or are authorized to manage (configured via environment variables).

    Requires: Windows PowerShell 5.1+ or PowerShell 7+.
    All comments are in English. The Vercel token is never logged or printed.
#>

# ----------------------------------------------------------------------------
# Global state (in-memory only; token plaintext never written unencrypted)
# ----------------------------------------------------------------------------
$script:ToolVersion              = '2.0.0'  # manager release version (single source of truth)
$script:Token                    = $null     # plaintext token, in memory only
$script:Account                  = $null     # cached /v2/user object (the signed-in identity)
$script:AvailableScopes          = @()       # personal + accessible team deployment scopes
$script:SelectedScope            = $null     # selected scope record; Kind is 'personal' or 'team'
$script:PersonalPlan             = $null     # personal workspace plan (best-effort)
$script:PersonalBillingStatus    = $null     # personal workspace billing state (active/trialing/...)
$script:PersonalBlocked          = $false
$script:ScopePlan                = $null     # selected deployment scope plan (best-effort)
$script:ScopeBillingStatus       = $null     # selected deployment scope billing state
$script:ScopeBlocked             = $false
$script:RememberedScopePreference = $null    # versioned preference loaded from a profile sidecar
$script:TeamListComplete         = $false    # true only when every /v2/teams page was loaded
$script:ProjectListComplete      = $false    # guards bulk deletion against partial pagination
$script:SelectedProject          = $null     # PSCustomObject: id, name, framework, url
$script:LastApiOk                = $false    # set by Invoke-VercelApi (true on HTTP success)
$script:LogFile                  = $null     # active deploy log path (set during a deploy)
$script:ActiveProfile            = $null     # name of the token profile currently loaded ($null = none)

$VercelApi = 'https://api.vercel.com'
# Directory the script lives in (used for the deploy log folder).
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Are we on Windows? $IsWindows is auto-defined in PowerShell 7 (true on Windows,
# false on Linux/macOS); it is UNDEFINED in Windows PowerShell 5.1, which only ever
# runs on Windows - so a $null value safely means "Windows". This single flag gates
# the few Windows-only code paths (DPAPI token vault).
$script:IsWindowsOS = if ($null -ne $IsWindows) { [bool]$IsWindows } else { $true }

# Ensure modern TLS for Windows PowerShell 5.1 (no-op on PS7).
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# UTF-8 console so box-drawing characters and glyphs render correctly.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ----------------------------------------------------------------------------
# UI palette. Glyphs/box characters are built from code points so the .ps1
# itself stays pure ASCII (robust across PS 5.1 ANSI and PS7 UTF-8 loaders).
# ----------------------------------------------------------------------------
$script:Ui = @{
    TL   = [char]0x256D; TR = [char]0x256E; BL = [char]0x2570; BR = [char]0x256F   # rounded corners
    H    = [char]0x2500; V  = [char]0x2502                                          # box lines
    OK   = [char]0x2713; ERR = [char]0x2717; WARN = [char]0x26A0                     # status glyphs
    INFO = [char]0x203A; DOT = [char]0x2022; ARR = [char]0x2192; TIP = [char]0x2726  # accents
}
# Braille spinner frames for the build animation.
$script:Spinner = @(0x280B,0x2819,0x2839,0x2838,0x283C,0x2834,0x2826,0x2827,0x2807,0x280F) |
                  ForEach-Object { [char]$_ }

# Contextual hints surfaced on the menu and at key moments.
$script:Tips = @(
    'Leave the project name blank to auto-generate a clean, realistic name.',
    'The client path must equal your 3x-ui / Xray inbound path - they are the same value.',
    'ALLOW_INSECURE=1 is only for self-signed backend certificates; leave it 0 otherwise.',
    'Hobby supports one function region; Pro and Enterprise support multiple regions.',
    'Pick [7], choose a project, and you jump straight into its actions menu.',
    'A 4xx during a health check is normal: it means the relay is live and forwarding.',
    'Every deploy writes a log and a local copy of the files under the script folder.',
    'Use a custom domain ([10]) so your client config never shows the *.vercel.app host.'
)
function Get-RandomTip { return $script:Tips[(Get-Random -Maximum $script:Tips.Count)] }

# ----------------------------------------------------------------------------
# Logging: a deploy session is captured to a file in <script dir>\logs\
# ----------------------------------------------------------------------------
function Add-LogLine {
    param([string]$Text, [string]$Level = 'INFO')
    if (-not $script:LogFile) { return }
    try {
        Add-Content -LiteralPath $script:LogFile -Encoding UTF8 `
            -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Text)
    } catch { }
}

# Write a (possibly multi-line) block to the log file only.
function Write-LogBlock {
    param([string]$Title, [string]$Content)
    if (-not $script:LogFile) { return }
    Add-LogLine ("---- {0} ----" -f $Title)
    foreach ($line in ($Content -split "`r?`n")) { Add-LogLine ("    " + $line) }
    Add-LogLine "---- end ----"
}

function Start-DeployLog {
    param([string]$ProjectName = 'project')
    $dir = Join-Path $script:ScriptDir 'logs'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safe  = ($ProjectName -replace '[^a-zA-Z0-9._-]', '_')
    $script:LogFile = Join-Path $dir ("deploy-{0}-{1}.log" -f $safe, $stamp)
    Add-LogLine ("=== XHTTP Relay deploy log :: project={0} ===" -f $ProjectName)
    $scope = if ($script:SelectedScope -and $script:SelectedScope.Kind -eq 'team') {
        "team:$($script:SelectedScope.Slug)"
    } else { 'personal' }
    $plan = if ($script:ScopePlan) { $script:ScopePlan } else { 'unknown' }
    $status = if ($script:ScopeBillingStatus) { $script:ScopeBillingStatus } else { 'unknown' }
    Add-LogLine ("scope={0} plan={1} billingStatus={2}" -f $scope, $plan, $status)
    Write-Host ("Logging this deploy to: {0}" -f $script:LogFile) -ForegroundColor Gray
}

function Stop-DeployLog {
    if ($script:LogFile) {
        Add-LogLine "=== end of deploy log ==="
        Write-Host ("Deploy log saved: {0}" -f $script:LogFile) -ForegroundColor Gray
        $script:LogFile = $null
    }
}

# ----------------------------------------------------------------------------
# Console output helpers (also tee to the active deploy log)
# ----------------------------------------------------------------------------
# Draw a rounded box around one or more lines (border + text colorized).
function Write-Box {
    param([string[]]$Lines, [System.ConsoleColor]$Color = 'Cyan',
          [System.ConsoleColor]$TextColor = 'White', [int]$Pad = 2)
    $u = $script:Ui
    $w = 0
    foreach ($l in $Lines) { if ($l.Length -gt $w) { $w = $l.Length } }
    $inner = $w + ($Pad * 2)
    Write-Host ('  ' + [string]$u.TL + ([string]$u.H * $inner) + [string]$u.TR) -ForegroundColor $Color
    foreach ($l in $Lines) {
        Write-Host ('  ' + [string]$u.V) -ForegroundColor $Color -NoNewline
        Write-Host ((' ' * $Pad) + $l + (' ' * ($w - $l.Length)) + (' ' * $Pad)) -ForegroundColor $TextColor -NoNewline
        Write-Host ([string]$u.V) -ForegroundColor $Color
    }
    Write-Host ('  ' + [string]$u.BL + ([string]$u.H * $inner) + [string]$u.BR) -ForegroundColor $Color
}

function Write-Title {
    param([string]$T)
    Add-LogLine $T
    Write-Host ""
    Write-Host ("  {0} {1}" -f $script:Ui.ARR, $T) -ForegroundColor Magenta
    Write-Host ("  " + ([string]$script:Ui.H * ($T.Length + 2))) -ForegroundColor DarkMagenta
}
function Write-Info { param([string]$T) Add-LogLine $T 'INFO';  Write-Host ("  {0} {1}" -f $script:Ui.INFO, $T) -ForegroundColor Gray }
function Write-Ok   { param([string]$T) Add-LogLine $T 'OK';    Write-Host ("  {0} {1}" -f $script:Ui.OK,   $T) -ForegroundColor Green }
function Write-Warn { param([string]$T) Add-LogLine $T 'WARN';  Write-Host ("  {0} {1}" -f $script:Ui.WARN, $T) -ForegroundColor Yellow }
function Write-Err  { param([string]$T) Add-LogLine $T 'ERROR'; Write-Host ("  {0} {1}" -f $script:Ui.ERR,  $T) -ForegroundColor Red }
function Write-Tip  { param([string]$T) Add-LogLine ("TIP: $T") 'TIP'; Write-Host ("  {0} {1}" -f $script:Ui.TIP, $T) -ForegroundColor DarkCyan }

# Aligned "label: value" line with a dim label and bright value.
function Write-KeyVal {
    param([string]$Key, [string]$Value, [System.ConsoleColor]$ValueColor = 'White')
    Write-Host ("    {0,-13}" -f $Key) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
}

function Show-Banner {
    # Center each line within the box so the title stays balanced even though
    # the GitHub URL is the widest line.
    $lines = @(
        'X H T T P   R E L A Y   D E P L O Y E R',
        ("v{0}  {1}  by @B3hnamR" -f $script:ToolVersion, $script:Ui.DOT),
        'Github : https://github.com/B3hnamR/XHTTPRelayECO'
    )
    $w = 0
    foreach ($l in $lines) { if ($l.Length -gt $w) { $w = $l.Length } }
    $centered = foreach ($l in $lines) {
        $left = [int][math]::Floor(($w - $l.Length) / 2)
        (' ' * $left) + $l
    }
    Write-Host ""
    Write-Box -Color Cyan -TextColor White -Pad 3 -Lines (@('') + $centered + @(''))
}

# Mask sensitive values for display (never print full secrets).
function Get-Masked {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '(empty)' }
    if ($Value.Length -le 6) { return ('*' * $Value.Length) }
    return ($Value.Substring(0, 2) + ('*' * 6) + $Value.Substring($Value.Length - 2))
}

# ----------------------------------------------------------------------------
# Screen / pacing helpers
# Clearing between actions keeps each screen self-contained: the user picks an
# option, sees ONLY that action's output, then returns to a fresh menu.
# ----------------------------------------------------------------------------
function Clear-Screen {
    try { Clear-Host } catch { try { [Console]::Clear() } catch { } }
}

# Hold the current screen until the user is ready, so output is not cleared away
# before it can be read. Called after every "leaf" action.
function Pause-Menu {
    Write-Host ""
    Write-Host ("  {0} Press Enter to continue..." -f $script:Ui.INFO) -ForegroundColor DarkGray
    [void](Read-Host)
}

# ----------------------------------------------------------------------------
# Input helpers (never crash on bad input)
# ----------------------------------------------------------------------------
function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        switch ($a.Trim().ToLower()) {
            'y'   { return $true }
            'yes' { return $true }
            'n'   { return $false }
            'no'  { return $false }
            default { Write-Warn "Please answer y or n." }
        }
    }
}

# Normalize a URL path so it always starts with "/" and has no trailing slash.
function Format-PathValue {
    param([string]$Path, [string]$Default = '/')
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $Default }
    $Path = $Path.Trim()
    if (-not $Path.StartsWith('/')) { $Path = '/' + $Path }
    if ($Path.Length -gt 1) { $Path = $Path.TrimEnd('/') }
    if ([string]::IsNullOrEmpty($Path)) { $Path = '/' }
    return $Path
}

# Validate that a backend URL is a well-formed http(s) URL.
function Test-BackendUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        $u = [uri]$Url
        return ($u.Scheme -in @('http', 'https')) -and -not [string]::IsNullOrWhiteSpace($u.Host)
    } catch { return $false }
}

# Convert ms-epoch (Vercel timestamps) to a readable local date.
function Format-Epoch {
    param($Ms)
    if (-not $Ms) { return 'n/a' }
    try { return ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Ms)).LocalDateTime.ToString('yyyy-MM-dd HH:mm') }
    catch { return 'n/a' }
}

# Normalize to LF-only line endings. Generated files come from here-strings, which
# inherit THIS script's on-disk line endings (CRLF on Windows, often CRLF after a
# transfer to Linux). Forcing LF makes every deployed file byte-identical across
# platforms. Strips any stray CR, then re-joins CRLF/CR as LF.
function ConvertTo-Lf {
    param([string]$Text)
    if ($null -eq $Text) { return $Text }
    return ($Text -replace "`r`n", "`n") -replace "`r", "`n"
}

# UTF-8 -> base64 (used for inline deployment file content). Always LF so the
# uploaded bytes do not depend on the platform the script runs on.
function ConvertTo-Base64Utf8 {
    param([string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Lf $Text)))
}

# Safely extract plaintext from a SecureString (PS 5.1 + 7 compatible).
function ConvertFrom-SecureStringToPlain {
    param([System.Security.SecureString]$Secure)
    if (-not $Secure) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ----------------------------------------------------------------------------
# Secure local token storage (current user only)
# Multiple named profiles let you keep several Vercel accounts side by side.
# Each profile is an encrypted file: <config>/profiles/<name>.dat
#   * Windows      -> DPAPI (tied to the Windows user account).
#   * Linux/macOS  -> AES-256 with a per-user random key in <config>/profiles/.vaultkey
#                     (the file is chmod 600, so only your user can read it).
# The legacy single-file token (<config>/token.dat) is auto-migrated to a
# profile named 'default' the first time it is encountered.
# ----------------------------------------------------------------------------
# Home directory of the current user, cross-platform. On Windows $env:USERPROFILE
# is set; on Linux/macOS it is empty, so fall back to $env:HOME (then to .NET).
function Get-HomeDir {
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $env:USERPROFILE }
    if (-not [string]::IsNullOrWhiteSpace($env:HOME))        { return $env:HOME }
    return [Environment]::GetFolderPath('UserProfile')
}
function Get-ConfigDir   { return (Join-Path (Get-HomeDir) '.xhttp-relay') }
function Get-TokenPath   { return (Join-Path (Get-ConfigDir) 'token.dat') }          # legacy single-token path
function Get-ProfilesDir { return (Join-Path (Get-ConfigDir) 'profiles') }

# Sanitize a user-supplied profile name into a safe file stem.
function Format-ProfileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $n = $Name.Trim().ToLower() -replace '[^a-z0-9._-]', '-'
    $n = $n.Trim('-')
    if ([string]::IsNullOrWhiteSpace($n)) { return $null }
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }
    return $n
}

function Get-ProfilePath {
    param([Parameter(Mandatory)][string]$Name)
    return (Join-Path (Get-ProfilesDir) ("{0}.dat" -f $Name))
}

# Scope preferences are deliberately separate from the encrypted token payload.
# This keeps existing .dat profiles compatible with older releases. The sidecar
# contains only non-secret workspace identifiers and is always validated against
# the authenticated user and the token's current team list before it is used.
function Get-ProfileScopePath {
    param([Parameter(Mandatory)][string]$Name)
    return (Join-Path (Get-ProfilesDir) ("{0}.scope.json" -f $Name))
}

function Read-ProfileScopePreference {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$UserId
    )
    $path = Get-ProfileScopePath $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $pref = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([int]$pref.version -ne 1) { throw 'unsupported version' }
        if ([string]::IsNullOrWhiteSpace([string]$pref.userId) -or [string]$pref.userId -cne $UserId) {
            throw 'profile belongs to a different Vercel user'
        }
        $kind = ([string]$pref.scopeType).Trim().ToLowerInvariant()
        if ($kind -notin @('personal', 'team')) { throw 'invalid scope type' }
        if ($kind -eq 'team' -and [string]::IsNullOrWhiteSpace([string]$pref.teamId)) {
            throw 'missing team id'
        }
        return [PSCustomObject]@{
            Kind = $kind
            Id   = if ($kind -eq 'team') { [string]$pref.teamId } else { $null }
            Slug = if ($kind -eq 'team') { [string]$pref.teamSlug } else { $null }
        }
    } catch {
        Write-Warn ("Saved scope preference for profile '{0}' is invalid; choose a scope again." -f $Name)
        return $null
    }
}

function Save-ProfileScopePreference {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:Account -or -not $script:SelectedScope) { return $false }
    $path = Get-ProfileScopePath $Name
    $payload = [ordered]@{
        version   = 1
        userId    = [string]$script:Account.id
        scopeType = [string]$script:SelectedScope.Kind
        teamId    = if ($script:SelectedScope.Kind -eq 'team') { [string]$script:SelectedScope.Id } else { $null }
        teamSlug  = if ($script:SelectedScope.Kind -eq 'team') { [string]$script:SelectedScope.Slug } else { $null }
    }
    try {
        $payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $path -Encoding UTF8
        try { if (-not $script:IsWindowsOS) { & chmod 600 $path 2>$null } } catch { }
        return $true
    } catch {
        Write-Warn ("Could not save the deployment-scope preference for profile '{0}'." -f $Name)
        return $false
    }
}

function Save-ActiveProfileScopePreference {
    if ($script:ActiveProfile) {
        [void](Save-ProfileScopePreference -Name $script:ActiveProfile)
    }
}

# Non-Windows token encryption key. DPAPI is Windows-only, so on Linux/macOS we
# encrypt the vault with AES-256 (via ConvertFrom/To-SecureString -Key) using a
# per-user random 32-byte key persisted beside the profiles in a 0600 file. On
# Windows this returns $null so the caller uses DPAPI instead. The key file uses
# a leading-dot, non-.dat name so it is never picked up as a saved profile.
function Get-VaultKey {
    if ($script:IsWindowsOS) { return $null }
    $dir = Get-ProfilesDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $keyPath = Join-Path $dir '.vaultkey'
    if (Test-Path $keyPath) {
        try {
            $k = [Convert]::FromBase64String((Get-Content -LiteralPath $keyPath -Raw).Trim())
            if ($k.Length -eq 32) { return $k }
        } catch { }
    }
    $key = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($key)
    Set-Content -LiteralPath $keyPath -Value ([Convert]::ToBase64String($key)) -Encoding ASCII
    try { & chmod 600 $keyPath 2>$null } catch { }   # owner-only on Unix
    return $key
}

# One-time migration: if the old token.dat exists and no 'default' profile does,
# move it into the profiles folder so existing users keep their saved token.
function Convert-LegacyToken {
    $legacy = Get-TokenPath
    if (-not (Test-Path $legacy)) { return }
    $dest = Get-ProfilePath 'default'
    if (Test-Path $dest) { return }
    try {
        $dir = Get-ProfilesDir
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Move-Item -LiteralPath $legacy -Destination $dest -Force
        Write-Info "Migrated your saved token to profile 'default'."
    } catch { }
}

# Return the names of all saved profiles (after migrating any legacy token).
function Get-SavedProfiles {
    Convert-LegacyToken
    $dir = Get-ProfilesDir
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.dat' -File -ErrorAction SilentlyContinue |
             ForEach-Object { $_.BaseName } | Sort-Object)
}

# Encrypt the in-memory token to a named profile (DPAPI, current user).
function Save-CurrentToken {
    param([string]$Name)
    if (-not $script:Token) { Write-Err "No token in memory to save."; return }
    if (-not $Name) {
        $suggest = if ($script:Account -and $script:Account.username) { $script:Account.username } else { 'default' }
        $suggest = Format-ProfileName $suggest
        $raw = Read-Host ("Profile name to save under [{0}]" -f $suggest)
        $Name = if ([string]::IsNullOrWhiteSpace($raw)) { $suggest } else { Format-ProfileName $raw }
    } else {
        $Name = Format-ProfileName $Name
    }
    if (-not $Name) { Write-Err "Invalid profile name."; return }

    $dir = Get-ProfilesDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Get-ProfilePath $Name
    if ((Test-Path $path) -and ($Name -ne $script:ActiveProfile)) {
        if (-not (Read-YesNo ("Profile '{0}' already exists. Overwrite it?" -f $Name) $false)) {
            Write-Info "Save cancelled."; return
        }
    }
    # Windows: ConvertFrom-SecureString uses DPAPI for the current user by default.
    # Linux/macOS: pass -Key so it uses portable AES-256 instead (DPAPI is absent).
    $sec = ConvertTo-SecureString $script:Token -AsPlainText -Force
    $key = Get-VaultKey
    $enc = if ($key) { ConvertFrom-SecureString $sec -Key $key } else { ConvertFrom-SecureString $sec }
    Set-Content -Path $path -Value $enc -Encoding ASCII
    $script:ActiveProfile = $Name
    [void](Save-ProfileScopePreference -Name $Name)
    $how = if ($script:IsWindowsOS) { 'DPAPI' } else { 'AES-256 + 0600 key file' }
    Write-Ok ("Token saved encrypted ({0}) as profile '{1}'." -f $how, $Name)
    Write-Info ("Location: {0}" -f $path)
    if ($script:IsWindowsOS) { Write-Info "Only this Windows user account can decrypt it." }
    else { Write-Info "Decryptable only with the key file in your profiles folder (owner-only)." }
}

# Decrypt a named profile into memory. With no name, prompts to pick one when
# several exist (or loads the only one). Returns $true on success.
function Load-SavedToken {
    param([string]$Name)
    $profiles = @(Get-SavedProfiles)
    if ($profiles.Count -eq 0) { Write-Err "No saved token profiles found."; return $false }

    if (-not $Name) {
        if ($profiles.Count -eq 1) {
            $Name = $profiles[0]
        } else {
            Write-Host ""
            Write-Host "Saved token profiles:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $profiles.Count; $i++) {
                $tag = if ($profiles[$i] -eq $script:ActiveProfile) { ' (active)' } else { '' }
                Write-Host ("  [{0}] {1}{2}" -f $i, $profiles[$i], $tag)
            }
            $sel = (Read-Host "Select profile number").Trim()
            $idx = -1
            if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 0 -and $idx -lt $profiles.Count) {
                $Name = $profiles[$idx]
            } else { Write-Err "Invalid selection."; return $false }
        }
    } else {
        $Name = Format-ProfileName $Name
    }

    $path = Get-ProfilePath $Name
    if (-not (Test-Path $path)) { Write-Err ("No saved profile named '{0}'." -f $Name); return $false }
    try {
        $enc = (Get-Content -Path $path -Raw).Trim()
        $key = Get-VaultKey                        # $null on Windows -> DPAPI decrypt
        $sec = if ($key) { ConvertTo-SecureString $enc -Key $key } else { ConvertTo-SecureString $enc }
        $script:Token = (ConvertFrom-SecureStringToPlain $sec).Trim()
        $script:ActiveProfile = $Name
        $script:RememberedScopePreference = $null
        Write-Ok ("Token loaded from profile '{0}'." -f $Name)
        return $true
    } catch {
        $why = if ($script:IsWindowsOS) { 'different Windows user or corrupted file' }
               else { 'missing/changed key file or corrupted vault' }
        Write-Err ("Failed to decrypt saved token ({0})." -f $why)
        return $false
    }
}

# Delete a named profile (prompts to pick when several exist).
function Remove-SavedToken {
    param([string]$Name)
    $profiles = @(Get-SavedProfiles)
    if ($profiles.Count -eq 0) { Write-Info "No saved token profiles to delete."; return }

    if (-not $Name) {
        if ($profiles.Count -eq 1) {
            $Name = $profiles[0]
        } else {
            Write-Host ""
            Write-Host "Saved token profiles:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $profiles.Count; $i++) {
                $tag = if ($profiles[$i] -eq $script:ActiveProfile) { ' (active)' } else { '' }
                Write-Host ("  [{0}] {1}{2}" -f $i, $profiles[$i], $tag)
            }
            $sel = (Read-Host "Select profile number to delete").Trim()
            $idx = -1
            if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 0 -and $idx -lt $profiles.Count) {
                $Name = $profiles[$idx]
            } else { Write-Err "Invalid selection."; return }
        }
    } else {
        $Name = Format-ProfileName $Name
    }

    $path = Get-ProfilePath $Name
    $scopePath = Get-ProfileScopePath $Name
    if (-not (Test-Path $path)) { Write-Err ("No saved profile named '{0}'." -f $Name); return }
    if (Read-YesNo ("Delete the saved profile '{0}'?" -f $Name) $true) {
        Remove-Item -LiteralPath $path -Force
        if (Test-Path -LiteralPath $scopePath) {
            try { Remove-Item -LiteralPath $scopePath -Force -ErrorAction Stop }
            catch { Write-Warn "The token was deleted, but its non-secret scope preference could not be removed." }
        }
        Write-Ok ("Profile '{0}' deleted." -f $Name)
        if ($Name -eq $script:ActiveProfile) {
            $script:ActiveProfile = $null
            $script:RememberedScopePreference = $null
        }
    }
}

# Switch to a different saved profile mid-session (load it, then re-validate).
function Switch-Profile {
    $profiles = @(Get-SavedProfiles)
    if ($profiles.Count -eq 0) { Write-Info "No saved profiles yet. Use [1] to login and save one."; return }
    if (Load-SavedToken) {
        [void](Complete-Login)
    }
}

# ----------------------------------------------------------------------------
# Vercel REST API wrapper
# ----------------------------------------------------------------------------
function Get-ApiErrorMessage {
    param($ErrorRecord)
    $detail = $null
    # PS 7 puts the response body here; PS 5.1 needs the response stream.
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $detail = $ErrorRecord.ErrorDetails.Message
    } elseif ($ErrorRecord.Exception.Response) {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $detail = $reader.ReadToEnd()
            $reader.Close()
        } catch { }
    }
    if ($detail) {
        try {
            $obj = $detail | ConvertFrom-Json
            if ($obj.error) {
                $code = $obj.error.code
                $msg  = $obj.error.message
                return "$code - $msg"
            }
        } catch { }
        return $detail
    }
    return $ErrorRecord.Exception.Message
}

function Invoke-VercelApi {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [object]    $Body,
        [hashtable] $Query,
        [bool]      $IncludeTeam = $true,
        [string]    $BaseUrl = $VercelApi   # override to hit a non-api host (e.g. vercel.com)
    )
    $script:LastApiOk = $false
    if (-not $script:Token) { Write-Err "Not logged in. Use [1] or [2] first."; return $null }

    $uri = "$BaseUrl$Path"

    # Build query string (always include teamId when a team scope is selected).
    $params = @{}
    if ($Query) { foreach ($k in $Query.Keys) { $params[$k] = $Query[$k] } }
    if ($IncludeTeam -and $script:SelectedScope -and $script:SelectedScope.Kind -eq 'team') {
        $params['teamId'] = [string]$script:SelectedScope.Id
    }
    if ($params.Count -gt 0) {
        $qs = ($params.GetEnumerator() | ForEach-Object {
            "{0}={1}" -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
        }) -join '&'
        $uri = "$uri`?$qs"
    }

    $headers = @{ Authorization = "Bearer $script:Token" }
    $irmArgs = @{
        Method      = $Method
        Uri         = $uri
        Headers     = $headers
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 25 -Compress }
        $irmArgs['Body'] = $json
    }

    try {
        $result = Invoke-RestMethod @irmArgs
        $script:LastApiOk = $true
        return $result
    } catch {
        $script:LastApiOk = $false
        Write-Err ("API error [{0} {1}]: {2}" -f $Method, $Path, (Get-ApiErrorMessage $_))
        return $null
    }
}

# ----------------------------------------------------------------------------
# Login / identity / deployment-scope selection
# ----------------------------------------------------------------------------
function Ensure-Login {
    if (-not $script:Token) { Write-Err "Please login first ([1] login or [2] load saved token)."; return $false }
    if (-not $script:SelectedScope) {
        Write-Err "No deployment scope is selected. Use [15] to choose one."
        return $false
    }
    return $true
}
function Ensure-Project {
    if (-not (Ensure-Login)) { return $false }
    if (-not $script:SelectedProject) { Write-Err "No project selected. Use [6] create or [7] select."; return $false }
    return $true
}

# Best-effort fields: these are present in current live Vercel responses but the
# billing object is only loosely documented. Unknown/missing values stay unknown.
function Get-PlanFromObject {
    param($Obj)
    if (-not $Obj) { return $null }
    foreach ($candidate in @($Obj.billing.plan, $Obj.plan)) {
        if ($candidate -and ($candidate -is [string])) {
            return $candidate.Trim().ToLowerInvariant()
        }
    }
    return $null
}

function Get-BillingStatusFromObject {
    param($Obj)
    if (-not $Obj) { return $null }
    foreach ($candidate in @($Obj.billing.status, $Obj.billingStatus)) {
        if ($candidate -and ($candidate -is [string])) {
            return $candidate.Trim().ToLowerInvariant()
        }
    }
    return $null
}

function Test-ObjectBlocked {
    param($Obj)
    if (-not $Obj) { return $false }
    return [bool]($Obj.blocked -or $Obj.softBlock)
}

function Format-PlanLabel {
    param(
        [string]$Plan,
        [string]$BillingStatus,
        [bool]$Blocked = $false
    )
    if ($Blocked) { return 'Paused' }
    $planLc = if ($Plan) { $Plan.Trim().ToLowerInvariant() } else { '' }
    $statusLc = if ($BillingStatus) { $BillingStatus.Trim().ToLowerInvariant() } else { '' }
    $label = switch ($planLc) {
        'pro'        { 'Pro' }
        'hobby'      { 'Hobby' }
        'enterprise' { 'Enterprise' }
        default {
            if ($planLc) { (Get-Culture).TextInfo.ToTitleCase($planLc) }
            else { 'Unknown' }
        }
    }
    if ($planLc -eq 'pro' -and $statusLc -eq 'trialing') { return 'Pro Trial' }
    return $label
}

function New-DeploymentScopeRecord {
    param(
        [Parameter(Mandatory)][ValidateSet('personal','team')][string]$Kind,
        [Parameter(Mandatory)]$Source,
        [bool]$IsDefault = $false
    )
    return [PSCustomObject]@{
        Kind          = $Kind
        Id            = if ($Kind -eq 'team') { [string]$Source.id } else { $null }
        Slug          = if ($Kind -eq 'team') { [string]$Source.slug } else { [string]$Source.username }
        Name          = if ($Kind -eq 'team') { [string]$Source.name } else { [string]$Source.username }
        Plan          = Get-PlanFromObject $Source
        BillingStatus = Get-BillingStatusFromObject $Source
        Blocked       = Test-ObjectBlocked $Source
        IsDefault     = $IsDefault
        Source        = $Source
    }
}

function Clear-AccountScopeState {
    param([switch]$ClearAccount)
    $script:AvailableScopes = @()
    $script:SelectedScope = $null
    $script:PersonalPlan = $null
    $script:PersonalBillingStatus = $null
    $script:PersonalBlocked = $false
    $script:ScopePlan = $null
    $script:ScopeBillingStatus = $null
    $script:ScopeBlocked = $false
    $script:TeamListComplete = $false
    $script:ProjectListComplete = $false
    $script:SelectedProject = $null
    if ($ClearAccount) { $script:Account = $null }
}

# Fetch every team page so a default or remembered workspace is never omitted.
function Get-AllTeams {
    $all = @()
    $until = $null
    $seen = @{}
    $script:TeamListComplete = $false
    while ($true) {
        $query = @{ limit = '100' }
        if ($until) { $query['until'] = [string]$until }
        $r = Invoke-VercelApi -Method 'GET' -Path '/v2/teams' -Query $query -IncludeTeam $false
        if (-not $r) { return $all }
        if ($r.teams) { $all += @($r.teams) }
        $next = if ($r.pagination -and $r.pagination.next) { [string]$r.pagination.next } else { $null }
        if (-not $next) {
            $script:TeamListComplete = $true
            return $all
        }
        if ($seen.ContainsKey($next)) {
            Write-Warn "Vercel returned a repeated team pagination cursor; the team list may be incomplete."
            return $all
        }
        $seen[$next] = $true
        $until = $next
    }
}

function Initialize-DeploymentScopes {
    if (-not $script:Account) { return }
    $defaultTeamId = [string]$script:Account.defaultTeamId
    $personal = New-DeploymentScopeRecord -Kind personal -Source $script:Account `
        -IsDefault ([string]::IsNullOrWhiteSpace($defaultTeamId))
    $script:PersonalPlan = $personal.Plan
    $script:PersonalBillingStatus = $personal.BillingStatus
    $script:PersonalBlocked = [bool]$personal.Blocked

    $scopes = @($personal)
    $teams = @(Get-AllTeams)
    foreach ($team in $teams) {
        $scopes += New-DeploymentScopeRecord -Kind team -Source $team `
            -IsDefault ([string]$team.id -ceq $defaultTeamId)
    }
    $script:AvailableScopes = @($scopes)
    if (-not $script:TeamListComplete) {
        Write-Warn "The accessible team list could not be loaded completely."
    } elseif ($defaultTeamId -and -not (@($scopes | Where-Object {
        $_.Kind -eq 'team' -and [string]$_.Id -ceq $defaultTeamId
    }).Count)) {
        Write-Warn "Vercel's default team is not accessible to this token; Personal will be suggested."
    }
}

function Test-ScopePreferenceAvailable {
    param([object[]]$Scopes, $Preference)
    if (-not $Preference) { return $false }
    foreach ($scope in @($Scopes)) {
        if ($Preference.Kind -eq 'personal' -and $scope.Kind -eq 'personal') { return $true }
        if ($Preference.Kind -eq 'team' -and $scope.Kind -eq 'team' -and
            [string]$scope.Id -ceq [string]$Preference.Id) { return $true }
    }
    return $false
}

function Get-PreferredScopeIndex {
    param(
        [object[]]$Scopes,
        $Preference,
        [string]$DefaultTeamId
    )
    $items = @($Scopes)
    if ($Preference) {
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($Preference.Kind -eq 'personal' -and $items[$i].Kind -eq 'personal') { return $i }
            if ($Preference.Kind -eq 'team' -and $items[$i].Kind -eq 'team' -and
                [string]$items[$i].Id -ceq [string]$Preference.Id) { return $i }
        }
    }
    if ($DefaultTeamId) {
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($items[$i].Kind -eq 'team' -and [string]$items[$i].Id -ceq $DefaultTeamId) { return $i }
        }
    }
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Kind -eq 'personal') { return $i }
    }
    return 0
}

# Health gate for the selected deployment scope. It warns rather than blocking,
# because Vercel may expose new benign billing states that this tool does not know.
function Test-DeploymentScopeStatus {
    param($User, [string]$Label = 'Deployment scope')
    if (-not $User) { return $true }
    $problems = @()

    # softBlock is null on a healthy account; an object when Vercel has blocked it
    # (e.g. spend cap reached, abuse review, payment issue).
    if ($User.softBlock) {
        $reason = if ($User.softBlock.reason) { $User.softBlock.reason } else { 'unspecified' }
        $problems += "$Label is SOFT-BLOCKED by Vercel (reason: $reason)."
    }
    # Some payloads expose a billing status; anything other than active/trialing is suspect.
    $bstatus = $null
    try { $bstatus = $User.billing.status } catch { }
    if ($bstatus -and ($bstatus -notmatch '^(active|trialing)$')) {
        $problems += "Billing status is '$bstatus' (expected 'active' or 'trialing')."
    }
    # Generic blocked flag some responses include.
    if ($User.blocked) { $problems += "$Label is flagged 'blocked'." }

    if ($problems.Count -gt 0) {
        Write-Host ""
        Write-Warn "===================== SCOPE STATUS WARNING ====================="
        foreach ($p in $problems) { Write-Warn ("  - {0}" -f $p) }
        Write-Warn "Deploys may be rejected until this is resolved in the dashboard:"
        Write-Warn "  https://vercel.com/account"
        Write-Warn "================================================================"
        Write-Host ""
        return $false
    }
    Write-Ok ("{0} status: active (no blocks detected)." -f $Label)
    return $true
}

function Set-DeploymentScope {
    param(
        [Parameter(Mandatory)]$Scope,
        [switch]$Persist
    )
    $oldKey = if ($script:SelectedScope) { "{0}:{1}" -f $script:SelectedScope.Kind, $script:SelectedScope.Id } else { '' }
    $newKey = "{0}:{1}" -f $Scope.Kind, $Scope.Id
    if ($oldKey -cne $newKey) { $script:SelectedProject = $null }

    $source = $Scope.Source
    if ($Scope.Kind -eq 'team') {
        $detail = Invoke-VercelApi -Method 'GET' -Path ("/v2/teams/{0}" -f $Scope.Id) -IncludeTeam $false
        if ($detail) {
            $source = if ($detail.team) { $detail.team } else { $detail }
        }
        else { Write-Warn "Could not refresh this team's billing metadata; using the team-list values." }
    } else {
        $source = $script:Account
    }

    $refreshedPlan = Get-PlanFromObject $source
    $refreshedStatus = Get-BillingStatusFromObject $source
    $Scope.Source = $source
    if ($refreshedPlan) { $Scope.Plan = $refreshedPlan }
    if ($refreshedStatus) { $Scope.BillingStatus = $refreshedStatus }
    $Scope.Blocked = [bool]($Scope.Blocked -or (Test-ObjectBlocked $source))
    $script:SelectedScope = $Scope
    $script:ScopePlan = $Scope.Plan
    $script:ScopeBillingStatus = $Scope.BillingStatus
    $script:ScopeBlocked = [bool]$Scope.Blocked

    $kindLabel = if ($Scope.Kind -eq 'team') { "Team $($Scope.Slug)" } else { "Personal $($Scope.Name)" }
    $planLabel = Format-PlanLabel -Plan $script:ScopePlan -BillingStatus $script:ScopeBillingStatus -Blocked $script:ScopeBlocked
    Write-Ok ("Deployment scope: {0} - {1}" -f $kindLabel, $planLabel)
    [void](Test-DeploymentScopeStatus -User $source -Label $kindLabel)
    if ($Persist) { Save-ActiveProfileScopePreference }
}

function Select-DeploymentScope {
    param(
        $PreferredScope,
        [switch]$AllowCancel,
        [switch]$Persist
    )
    $scopes = @($script:AvailableScopes)
    if ($scopes.Count -eq 0) { Write-Err "No deployment scopes are available."; return $false }

    $preferredAvailable = Test-ScopePreferenceAvailable -Scopes $scopes -Preference $PreferredScope
    if ($PreferredScope -and -not $preferredAvailable) {
        if (-not $script:TeamListComplete -and $PreferredScope.Kind -eq 'team') {
            Write-Warn "The remembered team could not be verified because the team list is incomplete. Retry login before deploying."
            return $false
        }
        Write-Warn "The remembered deployment scope is no longer accessible; choose another scope."
        $PreferredScope = $null
    }

    $defaultTeamId = [string]$script:Account.defaultTeamId
    $defaultTeamAvailable = @($scopes | Where-Object {
        $_.Kind -eq 'team' -and [string]$_.Id -ceq $defaultTeamId
    }).Count -gt 0
    if (-not $PreferredScope -and -not $script:TeamListComplete -and
        $defaultTeamId -and -not $defaultTeamAvailable) {
        Write-Warn "Vercel's default team could not be verified because the team list is incomplete."
        Write-Warn "No fallback scope was selected; retry login or menu [15]."
        return $false
    }

    $defaultIndex = Get-PreferredScopeIndex -Scopes $scopes -Preference $PreferredScope `
        -DefaultTeamId $defaultTeamId
    Write-Host ""
    Write-Host "Select deployment scope:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $scopes.Count; $i++) {
        $scope = $scopes[$i]
        $planLabel = Format-PlanLabel -Plan $scope.Plan -BillingStatus $scope.BillingStatus -Blocked ([bool]$scope.Blocked)
        $scopeLabel = if ($scope.Kind -eq 'team') { "Team: $($scope.Name) (slug: $($scope.Slug))" }
                      else { "Personal: $($scope.Name)" }
        $markers = @()
        if ($scope.IsDefault) { $markers += 'Vercel default' }
        if ($PreferredScope -and (($PreferredScope.Kind -eq 'personal' -and $scope.Kind -eq 'personal') -or
            ($PreferredScope.Kind -eq 'team' -and $scope.Kind -eq 'team' -and
             [string]$PreferredScope.Id -ceq [string]$scope.Id))) { $markers += 'remembered' }
        $markerText = if ($markers.Count -gt 0) { ' [' + ($markers -join ', ') + ']' } else { '' }
        Write-Host ("  [{0}] {1} - {2}{3}" -f $i, $scopeLabel, $planLabel, $markerText)
    }

    while ($true) {
        $prompt = if ($AllowCancel) { "Choice (default $defaultIndex, Q to cancel)" }
                  else { "Choice (default $defaultIndex)" }
        $raw = Read-Host $prompt
        if ($AllowCancel -and $raw -and $raw.Trim().ToLowerInvariant() -eq 'q') { return $false }
        $idx = $defaultIndex
        if (-not [string]::IsNullOrWhiteSpace($raw) -and
            -not [int]::TryParse($raw.Trim(), [ref]$idx)) {
            Write-Warn "Enter a listed scope number."
            continue
        }
        if ($idx -lt 0 -or $idx -ge $scopes.Count) {
            Write-Warn "Enter a listed scope number."
            continue
        }
        Set-DeploymentScope -Scope $scopes[$idx] -Persist:$Persist
        return $true
    }
}

function Switch-DeploymentScope {
    if (-not $script:Token -or -not $script:Account) {
        Write-Err "Please login first ([1] or [2])."
        return
    }
    $preferred = if ($script:SelectedScope) {
        [PSCustomObject]@{ Kind = $script:SelectedScope.Kind; Id = $script:SelectedScope.Id }
    } else { $null }
    $previousScopes = @($script:AvailableScopes)
    $previousComplete = $script:TeamListComplete
    $previousPersonalPlan = $script:PersonalPlan
    $previousPersonalStatus = $script:PersonalBillingStatus
    $previousPersonalBlocked = $script:PersonalBlocked
    Initialize-DeploymentScopes
    if (-not $script:TeamListComplete) {
        $script:AvailableScopes = $previousScopes
        $script:TeamListComplete = $previousComplete
        $script:PersonalPlan = $previousPersonalPlan
        $script:PersonalBillingStatus = $previousPersonalStatus
        $script:PersonalBlocked = $previousPersonalBlocked
        Write-Warn "Scope switching was cancelled because the current team list could not be verified."
        return
    }

    $currentStillAvailable = Test-ScopePreferenceAvailable `
        -Scopes $script:AvailableScopes -Preference $preferred
    if ($preferred -and -not $currentStillAvailable) {
        Write-Warn "The current deployment scope is no longer accessible. Select another scope before continuing."
        $script:SelectedScope = $null
        $script:ScopePlan = $null
        $script:ScopeBillingStatus = $null
        $script:ScopeBlocked = $false
        $script:SelectedProject = $null
        $preferred = $null
    }
    [void](Select-DeploymentScope -PreferredScope $preferred -AllowCancel -Persist)
}

# Validate the token, build all accessible scopes, and explicitly choose one.
function Complete-Login {
    $u = Invoke-VercelApi -Method 'GET' -Path '/v2/user' -IncludeTeam $false
    if (-not $u -or -not $u.user) {
        Write-Err "Token validation failed."
        $script:Token = $null
        Clear-AccountScopeState -ClearAccount
        return $false
    }

    Clear-AccountScopeState -ClearAccount
    $script:Account = $u.user
    Write-Ok ("Logged in as: {0}  ({1})" -f $u.user.username, $u.user.email)
    if ($script:ActiveProfile) {
        $script:RememberedScopePreference = Read-ProfileScopePreference `
            -Name $script:ActiveProfile -UserId ([string]$script:Account.id)
    } else {
        $script:RememberedScopePreference = $null
    }
    Initialize-DeploymentScopes
    if (-not (Select-DeploymentScope -PreferredScope $script:RememberedScopePreference -Persist)) {
        Write-Warn "Login succeeded, but no deployment scope was selected. Use [15] to retry."
        return $false
    }
    return $true
}

# Suggest a maxDuration that works WITHOUT requiring Fluid compute, based on plan.
# (Fluid compute, default on new projects, allows higher: Hobby 300 / Pro 800.)
function Get-SuggestedMaxDuration {
    $plan = $script:ScopePlan
    switch ($plan) {
        'enterprise' { return 900 }
        'pro'        { return 300 }
        'hobby'      { return 60 }
        default      { return 60 }   # safest universal default
    }
}

function Invoke-Login {
    $sec = Read-Host "Enter your Vercel API token" -AsSecureString
    $tok = (ConvertFrom-SecureStringToPlain $sec).Trim()
    if ([string]::IsNullOrWhiteSpace($tok)) { Write-Err "No token entered."; return }
    $script:ActiveProfile = $null
    $script:RememberedScopePreference = $null
    Clear-AccountScopeState -ClearAccount
    $script:Token = $tok
    if (Complete-Login) {
        if (Read-YesNo "Save this token encrypted for next time?" $true) { Save-CurrentToken }
    }
}

function Show-AccountInfo {
    if (-not (Ensure-Login)) { return }
    $u = Invoke-VercelApi -Method 'GET' -Path '/v2/user' -IncludeTeam $false
    if (-not $u) { return }
    $user = $u.user
    $personalPlan = Format-PlanLabel -Plan (Get-PlanFromObject $user) `
        -BillingStatus (Get-BillingStatusFromObject $user) -Blocked (Test-ObjectBlocked $user)
    $scopeLabel = if ($script:SelectedScope.Kind -eq 'team') {
        "Team $($script:SelectedScope.Name) ($($script:SelectedScope.Slug))"
    } else { "Personal $($user.username)" }
    $scopePlan = Format-PlanLabel -Plan $script:ScopePlan `
        -BillingStatus $script:ScopeBillingStatus -Blocked $script:ScopeBlocked

    Write-Title "Account and Deployment Scope"
    Write-KeyVal 'Signed in as' ([string]$user.username) 'White'
    Write-KeyVal 'Name' ([string]$user.name) 'White'
    Write-KeyVal 'Email' ([string]$user.email) 'White'
    Write-KeyVal 'User ID' ([string]$user.id) 'Gray'
    Write-KeyVal 'Personal plan' $personalPlan 'White'
    Write-KeyVal 'Deploy scope' $scopeLabel 'Green'
    Write-KeyVal 'Scope plan' $scopePlan 'White'
    $prof = if ($script:ActiveProfile) { $script:ActiveProfile } else { '(not saved)' }
    Write-KeyVal 'Profile' $prof 'White'
    Write-KeyVal 'Max duration' ((Get-SuggestedMaxDuration).ToString() + 's suggested') 'Gray'
}

# ----------------------------------------------------------------------------
# Deployment-scope usage & status  (Vercel billing-cycle usage summary)
# ----------------------------------------------------------------------------
# Mirrors the BehnamBot "Usage and status" view. Vercel's dashboard exposes a
# per-cycle usage summary at https://vercel.com/api/usage-summary (a different
# host than api.vercel.com). Values are raw base units; convert per metric type.
function Format-UsageValue {
    param($Value, [string]$Type)
    $ci = [Globalization.CultureInfo]::GetCultureInfo('en-US')
    $v = 0.0
    [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, $ci, [ref]$v) | Out-Null
    switch ($Type) {
        'gb'   { return (($v / 1e9).ToString('N2', $ci) + ' GB') }
        'gbhr' { return (($v / 3.6e9).ToString('N1', $ci) + ' GB-Hrs') }
        'duration' {
            $total = [int][math]::Round($v / 1000.0)   # value is milliseconds
            if ($total -lt 0) { $total = 0 }
            $h = [math]::Floor($total / 3600)
            $m = [math]::Floor(($total % 3600) / 60)
            $s = $total % 60
            if ($h -gt 0) { if ($m -gt 0) { return ('{0}h {1}m' -f $h, $m) } else { return ('{0}h' -f $h) } }
            if ($m -gt 0) { if ($s -gt 0) { return ('{0}m {1}s' -f $m, $s) } else { return ('{0}m' -f $m) } }
            return ('{0}s' -f $s)
        }
        default { return ([math]::Round($v)).ToString('N0', $ci) }   # count, thousands-separated
    }
}

function Format-UsageCycle {
    param($Cycle)
    if (-not $Cycle -or -not $Cycle.start -or -not $Cycle.end) { return '' }
    $ci = [Globalization.CultureInfo]::GetCultureInfo('en-US')
    try {
        $s = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Cycle.start)).LocalDateTime
        $e = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Cycle.end)).LocalDateTime
        return ('{0} - {1}' -f $s.ToString('MMM d, hh:mm tt', $ci), $e.ToString('MMM d, hh:mm tt', $ci))
    } catch { return '' }
}

# The dashboard-only usage endpoint silently defaults to user.defaultTeamId when
# no teamId is supplied. Never accept those metrics as Personal workspace data.
function Test-UsageSummaryMatchesScope {
    param($Summary, $Scope)
    if (-not $Summary -or -not $Scope) { return $false }
    $reportedTeamId = [string]$Summary.teamId
    $reportedPlan = if ($Summary.plan) { ([string]$Summary.plan).Trim().ToLowerInvariant() } else { '' }
    $scopePlan = if ($Scope.Plan) { ([string]$Scope.Plan).Trim().ToLowerInvariant() } else { '' }
    if ($Scope.Kind -eq 'team') {
        return -not [string]::IsNullOrWhiteSpace($reportedTeamId) -and
               $reportedTeamId -ceq [string]$Scope.Id
    }
    if (-not [string]::IsNullOrWhiteSpace($reportedTeamId)) { return $false }
    # An unscoped dashboard call is only plausibly Personal when Vercel itself
    # says Personal is the default workspace. Otherwise it cannot be proven.
    if (-not $Scope.IsDefault) { return $false }
    return -not ($reportedPlan -and $scopePlan -and $reportedPlan -ne $scopePlan)
}

function Show-AccountUsage {
    if (-not (Ensure-Login)) { return }

    $r = Invoke-VercelApi -Method 'GET' -Path '/api/usage-summary' -BaseUrl 'https://vercel.com'
    $scopeMismatch = $r -and -not (Test-UsageSummaryMatchesScope -Summary $r -Scope $script:SelectedScope)
    if ($scopeMismatch) { $r = $null }

    Write-Title "Vercel Usage"

    # Token / profile.
    $tok = if ($script:ActiveProfile) { $script:ActiveProfile } else { Get-Masked $script:Token }
    Write-KeyVal 'Token' $tok 'Cyan'

    # Always display the selected scope's canonical metadata. Usage data is never
    # allowed to change the plan/status shown for that scope.
    $status = Format-PlanLabel -Plan $script:ScopePlan `
        -BillingStatus $script:ScopeBillingStatus -Blocked $script:ScopeBlocked
    Write-KeyVal 'Scope plan' $status 'White'
    $scopeText = if ($script:SelectedScope.Kind -eq 'team') { "Team $($script:SelectedScope.Slug)" }
                 else { "Personal $($script:Account.username)" }
    Write-KeyVal 'Deploy scope' $scopeText 'White'
    if ($scopeMismatch) {
        Write-Host ""
        if ($script:SelectedScope.Kind -eq 'personal') {
            Write-Warn "Vercel returned usage for the default team, not the selected Personal scope."
            Write-Warn "Personal usage is unavailable from this endpoint; team metrics were ignored."
        } else {
            Write-Warn "Vercel returned usage for a different workspace; those metrics were ignored."
        }
    }

    # Billing cycle.
    if ($r) {
        $cycle = Format-UsageCycle $r.cycle
        if ($cycle) { Write-KeyVal 'Cycle' $cycle 'Gray' }
    }

    # Usage rows: id / label / type / fallback-limit mirror BehnamBot VERCEL_USAGE_ROWS.
    $rows = @(
        @{ id = 'networking-fast-data-transfer';        label = 'Fast Data Transfer';        type = 'gb';       limit = '100.00 GB' }
        @{ id = 'networking-fast-origin-transfer';      label = 'Fast Origin Transfer';      type = 'gb';       limit = '10.00 GB' }
        @{ id = 'networking-edge-requests';             label = 'Edge Requests';             type = 'count';    limit = '1,000,000' }
        @{ id = 'vercel-functions-invocations';         label = 'Function Invocations';      type = 'count';    limit = '1,000,000' }
        @{ id = 'networking-edge-request-cpu-duration'; label = 'Edge Request CPU Duration'; type = 'duration'; limit = '1h' }
        @{ id = 'vercel-functions-fluid-duration';      label = 'Fluid Provisioned Memory';  type = 'gbhr';     limit = '360.0 GB-Hrs' }
        @{ id = 'vercel-functions-fluid-cpu-duration';  label = 'Fluid Active CPU';          type = 'duration'; limit = '4h' }
        @{ id = 'networking-microfrontends-routing';    label = 'Microfrontends Routing';    type = 'count';    limit = '50,000' }
        @{ id = 'isr-reads';                            label = 'ISR Reads';                 type = 'count';    limit = '1,000,000' }
        @{ id = 'isr-writes';                           label = 'ISR Writes';                type = 'count';    limit = '200,000' }
    )

    $usage = if ($r -and $r.data) { @($r.data.usage) } else { @() }
    if (-not $usage -or $usage.Count -eq 0) {
        Write-Host ""
        Write-Warn "Usage summary is unavailable for this token/scope (showing limits only)."
    }

    # Index returned items by id and by normalized title.
    $byId = @{}; $byTitle = @{}
    foreach ($it in $usage) {
        if ($it.id)    { $byId[[string]$it.id] = $it }
        if ($it.title) { $byTitle[((([string]$it.title) -replace '\s+', ' ').Trim().ToLower())] = $it }
    }

    Write-Host ""
    foreach ($row in $rows) {
        $item = $null
        if     ($byId.ContainsKey($row.id))                 { $item = $byId[$row.id] }
        elseif ($byTitle.ContainsKey($row.label.ToLower())) { $item = $byTitle[$row.label.ToLower()] }
        if ($item) {
            $val = Format-UsageValue $item.value $row.type
            if ($null -ne $item.limit -and ([double]$item.limit) -gt 0) { $lim = Format-UsageValue $item.limit $row.type }
            else { $lim = $row.limit }
        } else {
            $val = Format-UsageValue 0 $row.type
            $lim = $row.limit
        }
        Write-Host ("{0}: {1} / {2}" -f $row.label, $val, $lim)
    }
}

# ----------------------------------------------------------------------------
# Projects: list / select / create / delete
# ----------------------------------------------------------------------------
function Set-SelectedProject {
    param($P)
    # Always present the stable, short production host (<name>.vercel.app),
    # never the long per-deploy URL.
    $script:SelectedProject = [PSCustomObject]@{
        id         = $P.id
        name       = $P.name
        framework  = $P.framework
        url        = "$($P.name).vercel.app"
        backendUrl = ''   # cached for the region auto-hint on redeploy
        path       = ''   # cached single path (client = inbound) for templates
    }
}

function Show-Projects {
    if (-not (Ensure-Login)) { return $null }
    $res = Invoke-VercelApi -Method 'GET' -Path '/v9/projects' -Query @{ limit = '100' }
    if (-not $res) { return $null }
    $projects = @($res.projects)
    if ($projects.Count -eq 0) { Write-Info "No projects found in this scope."; return @() }

    Write-Title "Projects"
    for ($i = 0; $i -lt $projects.Count; $i++) {
        $p = $projects[$i]
        $fw = if ($p.framework) { $p.framework } else { '(none / Other)' }
        Write-Host ("  {0} " -f $script:Ui.DOT) -ForegroundColor DarkCyan -NoNewline
        Write-Host ("[{0}] " -f $i) -ForegroundColor Cyan -NoNewline
        Write-Host $p.name -ForegroundColor White
        Write-KeyVal 'url'     ("https://{0}.vercel.app" -f $p.name) 'Green'
        Write-KeyVal 'id'      $p.id 'Gray'
        Write-KeyVal 'type'    $fw 'Gray'
        Write-KeyVal 'updated' (Format-Epoch $p.updatedAt) 'Gray'
    }
    return $projects
}

# Action sub-menu shown right after a project is selected.
function Show-ProjectActions {
    if (-not $script:SelectedProject) { return }
    while ($true) {
        if (-not $script:SelectedProject) { return }   # e.g. after a delete
        Clear-Screen
        Write-Title ("Project :: {0}" -f $script:SelectedProject.name)
        Write-KeyVal 'url' ("https://{0}" -f $script:SelectedProject.url) 'Green'
        Write-KeyVal 'id'  $script:SelectedProject.id 'Gray'
        Write-Host ""
        Write-MenuItem '1' 'Configure environment variables'
        Write-MenuItem '2' 'Deploy / redeploy relay code'
        Write-MenuItem '3' 'Custom domains  (list / add / verify / remove)'
        Write-MenuItem '4' 'Generate client config  (auto host + path, asks only UUID)'
        Write-MenuItem '5' 'Run health check'
        Write-MenuItem '6' 'Delete this project'
        Write-MenuItem '0' 'Back to main menu'
        $c = (Read-Host "  Choice").Trim()
        if ($c -eq '0') { return }
        Clear-Screen
        switch ($c) {
            '1' { Invoke-EnvMenu }     # self-paced sub-menu (no extra pause below)
            '2' { Deploy-Relay }
            '3' { Invoke-DomainMenu }  # self-paced sub-menu
            '4' { New-QuickClientConfig -PublicHost $script:SelectedProject.url -Path (Get-CurrentRelayPath) }
            '5' { Invoke-HealthCheck -PublicHost $script:SelectedProject.url }
            '6' { Remove-Project; if (-not $script:SelectedProject) { return } }
            default { Write-Warn "Unknown option." }
        }
        # 1 and 3 are self-paced sub-menus; the rest are leaf screens to hold.
        if ($c -notin @('1','3')) { Pause-Menu }
    }
}

function Select-Project {
    $projects = Show-Projects
    if (-not $projects -or @($projects).Count -eq 0) { Pause-Menu; return }
    $projects = @($projects)
    $sel = (Read-Host "  Select project number").Trim()
    $idx = -1
    if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 0 -and $idx -lt $projects.Count) {
        Set-SelectedProject $projects[$idx]
        Show-ProjectActions   # jump straight into actions (self-paced) for the chosen project
    } else {
        Write-Err "Invalid selection."
        Pause-Menu
    }
}

# Generate a natural-looking, lowercase, hyphenated project name. The words are
# deliberately mundane (nature / colors / everyday objects) and avoid ALL
# networking jargon (proxy, relay, tunnel, gateway, vpn, router, mesh, node, ...)
# because such keywords in a *.vercel.app hostname can get the deployment
# filtered or blocked by upstream networks — a jargon-heavy name failed to ping
# while plain names on the same backend worked during live testing.
function New-RandomProjectName {
    $first = @('amber','autumn','azure','breezy','bright','calm','clever','copper','coral',
               'cozy','crimson','crystal','dewy','dusky','emerald','fancy','fresh','frosty',
               'gentle','golden','happy','hazel','hidden','honey','indigo','ivory','jade',
               'jolly','lemon','lively','lucky','lunar','maple','mellow','merry','misty',
               'olive','opal','pearl','plum','quiet','rosy','ruby','rustic','sage','sandy',
               'scarlet','silver','snowy','solar','sunny','swift','teal','tidy','velvet',
               'violet','warm','willow','wispy','zesty')
    $second = @('acorn','anchor','apple','arbor','aspen','badger','basin','birch','bloom',
                'brook','canyon','cedar','cliff','clover','comet','cove','creek','daisy',
                'dale','dune','ember','fern','field','finch','forest','garden','glade',
                'grove','harbor','haven','heron','hill','island','juniper','lake','leaf',
                'lily','lotus','meadow','moss','oak','oasis','orchard','otter','palm',
                'peak','pebble','pine','pond','poppy','rabbit','ridge','river','robin',
                'sparrow','spruce','summit','thicket','trail','vale','valley','willow','wren')
    $a = $first[(Get-Random -Maximum $first.Count)]
    $b = $second[(Get-Random -Maximum $second.Count)]
    while ($b -eq $a) { $b = $second[(Get-Random -Maximum $second.Count)] }  # avoid "willow-willow"
    $name = "$a-$b"
    # Append a small numeric suffix some of the time to help uniqueness.
    if ((Get-Random -Maximum 10) -lt 4) { $name = ("{0}-{1}" -f $name, (Get-Random -Minimum 2 -Maximum 99)) }
    return $name
}

# Interactively collect + validate a project name WITHOUT touching the API.
# Returns a valid lowercase name, or $null if the entry was invalid. Splitting
# this out lets the guided flow gather a name before anything is created.
function Read-ProjectName {
    $Name = Read-Host "Project name (lowercase letters/numbers/hyphens) - Enter to auto-generate"
    if ([string]::IsNullOrWhiteSpace($Name)) {
        while ($true) {
            $gen = New-RandomProjectName
            $ans = Read-Host ("Suggested: '{0}'  [Enter]=use  r=regenerate  or type your own" -f $gen)
            if ([string]::IsNullOrWhiteSpace($ans)) { $Name = $gen; break }
            elseif ($ans.Trim().ToLower() -eq 'r') { continue }
            else { $Name = $ans; break }
        }
    }
    $Name = $Name.Trim().ToLower()
    if ($Name -notmatch '^[a-z0-9][a-z0-9._-]{0,99}$') {
        Write-Err "Invalid project name. Use lowercase letters, numbers, '.', '_', '-'."
        return $null
    }
    return $Name
}

function New-Project {
    param([string]$Name)
    if (-not (Ensure-Login)) { return $null }
    if (-not $Name) { $Name = Read-ProjectName }
    if (-not $Name) { return $null }
    $Name = $Name.Trim().ToLower()
    if ($Name -notmatch '^[a-z0-9][a-z0-9._-]{0,99}$') {
        Write-Err "Invalid project name. Use lowercase letters, numbers, '.', '_', '-'."
        return $null
    }
    # framework=null => "Other" (plain Node.js serverless function project, no Git).
    $body = [ordered]@{ name = $Name; framework = $null }
    $res = Invoke-VercelApi -Method 'POST' -Path '/v11/projects' -Body $body
    if (-not $res) { return $null }
    Write-Ok ("Project created: {0}  (id: {1})" -f $res.name, $res.id)
    Set-SelectedProject $res
    return $res
}

function Remove-Project {
    if (-not (Ensure-Project)) { return }
    Write-Warn "You are about to DELETE this project:"
    Write-Host ("  Name: {0}" -f $script:SelectedProject.name)
    Write-Host ("  ID:   {0}" -f $script:SelectedProject.id)
    if (-not (Read-YesNo "Are you absolutely sure?" $false)) { Write-Info "Aborted."; return }
    $confirm = Read-Host ("Re-type the project name '{0}' to confirm deletion" -f $script:SelectedProject.name)
    if ($confirm -ne $script:SelectedProject.name) { Write-Err "Name mismatch. Deletion aborted."; return }

    $null = Invoke-VercelApi -Method 'DELETE' -Path "/v9/projects/$($script:SelectedProject.id)"
    if ($script:LastApiOk) {
        Write-Ok "Project deleted."
        $script:SelectedProject = $null
    }
}

# Paginate the FULL project list for the current scope (Show-Projects only fetches
# the first 100). Follows Vercel's pagination.next cursor via the 'until' param.
function Get-AllProjects {
    $all = @()
    $until = $null
    $seen = @{}
    $script:ProjectListComplete = $false
    while ($true) {
        $q = @{ limit = '100' }
        if ($until) { $q['until'] = [string]$until }
        $res = Invoke-VercelApi -Method 'GET' -Path '/v9/projects' -Query $q
        if (-not $res) { return $all }
        if ($res.projects) { $all += @($res.projects) }
        $next = if ($res.pagination -and $res.pagination.next) { [string]$res.pagination.next } else { $null }
        if (-not $next) {
            $script:ProjectListComplete = $true
            return $all
        }
        if ($seen.ContainsKey($next)) {
            Write-Warn "Vercel returned a repeated project pagination cursor."
            return $all
        }
        $seen[$next] = $true
        $until = $next
    }
}

# Bulk-delete EVERY project in the current scope. Heavily gated: explicit yes/no
# plus a typed confirmation phrase, since this is irreversible.
function Remove-AllProjects {
    if (-not (Ensure-Login)) { return }
    $scope = if ($script:SelectedScope.Kind -eq 'team') {
        "team '$($script:SelectedScope.Slug)'"
    } else { 'your personal account' }

    Write-Info ("Fetching all projects in {0} ..." -f $scope)
    $projects = @(Get-AllProjects)
    if (-not $script:ProjectListComplete) {
        Write-Err "The complete project list could not be verified; bulk deletion was refused."
        return
    }
    if ($projects.Count -eq 0) { Write-Info "No projects found in this scope. Nothing to delete."; return }

    Write-Title "Delete ALL Projects"
    Write-Warn ("You are about to permanently DELETE all {0} project(s) in {1}:" -f $projects.Count, $scope)
    foreach ($p in $projects) { Write-Host ("  {0} {1}" -f $script:Ui.DOT, $p.name) -ForegroundColor Gray }
    Write-Host ""
    Write-Warn "This cannot be undone. Deployments, domains, and env vars for these projects are lost."

    if (-not (Read-YesNo ("Delete ALL {0} project(s)?" -f $projects.Count) $false)) { Write-Info "Aborted."; return }
    $confirm = Read-Host "Type 'DELETE ALL' (exactly) to confirm"
    if ($confirm -ne 'DELETE ALL') { Write-Err "Confirmation text did not match. Deletion aborted."; return }

    $ok = 0; $fail = 0
    $selectedId = if ($script:SelectedProject) { $script:SelectedProject.id } else { $null }
    foreach ($p in $projects) {
        $null = Invoke-VercelApi -Method 'DELETE' -Path "/v9/projects/$($p.id)"
        if ($script:LastApiOk) {
            $ok++; Write-Ok ("Deleted: {0}" -f $p.name)
            if ($selectedId -and $p.id -eq $selectedId) { $script:SelectedProject = $null }
        } else {
            $fail++; Write-Err ("Failed:  {0}" -f $p.name)
        }
    }
    Write-Host ""
    if ($fail -eq 0) { Write-Ok ("Done. Deleted {0} of {1} project(s)." -f $ok, $projects.Count) }
    else { Write-Warn ("Done. Deleted {0} of {1} project(s); {2} failed." -f $ok, $projects.Count, $fail) }
}

# ----------------------------------------------------------------------------
# Environment variables
# ----------------------------------------------------------------------------
function Get-EnvVars {
    if (-not (Ensure-Project)) { return $null }
    $res = Invoke-VercelApi -Method 'GET' -Path "/v9/projects/$($script:SelectedProject.id)/env"
    if ($res -and $res.envs) { return @($res.envs) }
    return @()
}

function Show-EnvVars {
    $envs = Get-EnvVars
    if ($null -eq $envs) { return }
    if (@($envs).Count -eq 0) { Write-Info "No environment variables set."; return }
    Write-Title "Environment Variables"
    Write-Host ("{0,-16} {1,-12} {2,-26} {3}" -f 'KEY', 'TYPE', 'TARGET', 'VALUE') -ForegroundColor Cyan
    foreach ($e in $envs) {
        $tgt = if ($e.target) { (@($e.target) -join ',') } else { '' }
        # 'plain' vars are intentionally non-secret (RELAY_PATH, ALLOW_INSECURE)
        # - show them in full; mask only encrypted/secret values.
        $val = if (-not $e.value) { '(hidden by Vercel)' }
               elseif ($e.type -eq 'plain') { $e.value }
               else { Get-Masked $e.value }
        Write-Host ("{0,-16} {1,-12} {2,-26} {3}" -f $e.key, $e.type, $tgt, $val)
    }
}

# Upsert a single environment variable across all targets.
function Set-EnvVar {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Value,
        [string]   $Type   = 'encrypted',
        [string[]] $Target = @('production', 'preview', 'development')
    )
    if (-not (Ensure-Project)) { return }
    $body = [ordered]@{
        key    = $Key
        value  = $Value
        type   = $Type
        target = $Target
    }
    $null = Invoke-VercelApi -Method 'POST' `
        -Path "/v10/projects/$($script:SelectedProject.id)/env" `
        -Body $body -Query @{ upsert = 'true' }
    if ($script:LastApiOk) { Write-Ok ("Saved env: {0}" -f $Key) }
}

function Remove-EnvVarInteractive {
    $envs = @(Get-EnvVars)
    if ($envs.Count -eq 0) { Write-Info "No variables to remove."; return }
    for ($i = 0; $i -lt $envs.Count; $i++) {
        Write-Host ("[{0}] {1} ({2})" -f $i, $envs[$i].key, (@($envs[$i].target) -join ','))
    }
    $sel = Read-Host "Select variable number to remove"
    $idx = -1
    if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 0 -and $idx -lt $envs.Count) {
        $e = $envs[$idx]
        if (Read-YesNo ("Remove '{0}'?" -f $e.key) $false) {
            $null = Invoke-VercelApi -Method 'DELETE' -Path "/v9/projects/$($script:SelectedProject.id)/env/$($e.id)"
            if ($script:LastApiOk) { Write-Ok ("Removed '{0}'." -f $e.key) }
        }
    } else {
        Write-Err "Invalid selection."
    }
}

function Invoke-EnvMenu {
    if (-not (Ensure-Project)) { Pause-Menu; return }
    while ($true) {
        Clear-Screen
        Write-Title ("Environment Variables :: {0}" -f $script:SelectedProject.name)
        Write-MenuItem '1' 'View existing variables'
        Write-MenuItem '2' 'Add/Update BACKEND_URL'
        Write-MenuItem '3' 'Add/Update Path        (client = inbound path)'
        Write-MenuItem '4' 'Add/Update ALLOW_INSECURE'
        Write-MenuItem '5' 'Add/Update custom KEY = VALUE'
        Write-MenuItem '6' 'Remove a variable'
        Write-MenuItem '7' 'Redeploy now (apply changes)'
        Write-MenuItem '0' 'Back to main menu'
        $c = (Read-Host "  Choice").Trim()
        if ($c -eq '0') { return }
        Clear-Screen
        switch ($c) {
            '1' { Show-EnvVars }
            '2' {
                $v = ''
                while (-not (Test-BackendUrl $v)) {
                    $v = Read-Host "BACKEND_URL (e.g. https://backend.example.com:8443)"
                    if (-not (Test-BackendUrl $v)) { Write-Warn "Enter a valid http(s) URL." }
                }
                Set-EnvVar -Key 'BACKEND_URL' -Value $v.Trim()
                $script:SelectedProject.backendUrl = $v.Trim()
            }
            '3' {
                Write-Info "The single path used by BOTH your client and your 3x-ui/Xray inbound."
                Write-Info "Press Enter to accept the shown default; otherwise type your inbound path."
                $p = Format-PathValue (Read-Host 'Path (must match your inbound) [/api]') '/api'
                Write-Info ("Using path: {0}" -f $p)
                Set-EnvVar -Key 'RELAY_PATH' -Value $p -Type 'plain'
                $script:SelectedProject.path = $p
            }
            '4' {
                Write-Info "Y = skip backend TLS verification (self-signed cert). N = verify it."
                $v = if (Read-YesNo "Allow insecure backend TLS (self-signed cert)?" $true) { '1' } else { '0' }
                Set-EnvVar -Key 'ALLOW_INSECURE' -Value $v -Type 'plain'
            }
            '5' {
                $k = Read-Host 'Key'
                if (-not [string]::IsNullOrWhiteSpace($k)) {
                    $val = Read-Host 'Value'
                    Set-EnvVar -Key $k.Trim() -Value $val
                }
            }
            '6' { Remove-EnvVarInteractive }
            '7' { Deploy-Relay }
            default { Write-Warn "Unknown option." }
        }
        Pause-Menu
    }
}

# ----------------------------------------------------------------------------
# Function region selection (auto-hint from the backend's DNS / geo-IP)
# ----------------------------------------------------------------------------
$script:AllRegionCodes = @('arn1','bom1','cdg1','cle1','cpt1','dub1','dxb1','fra1','gru1','hkg1',
                           'hnd1','iad1','icn1','kix1','lhr1','pdx1','sfo1','sin1','syd1','yul1')

function Get-HostFromUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    try { return ([uri]$Url).Host } catch { return $null }
}

# Resolve IPv4 addresses for a hostname (Resolve-DnsName, fallback to .NET).
function Resolve-HostIps {
    param([string]$HostName)
    $ips = @()
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $ips }
    try {
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            $rec = Resolve-DnsName -Name $HostName -Type A -ErrorAction Stop
            $ips = @($rec | Where-Object { $_.Type -eq 'A' -and $_.IPAddress } | ForEach-Object { $_.IPAddress })
        }
    } catch { }
    if ($ips.Count -eq 0) {
        try {
            $addr = [System.Net.Dns]::GetHostAddresses($HostName)
            $ips = @($addr | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
        } catch { }
    }
    return @($ips | Select-Object -Unique)
}

# Best-effort geo lookup of YOUR backend IP (read-only public metadata).
function Get-IpCountry {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $null }
    try {
        $r = Invoke-RestMethod -Method GET -TimeoutSec 6 -ErrorAction Stop `
            -Uri ("http://ip-api.com/json/{0}?fields=status,country,countryCode" -f $Ip)
        if ($r.status -eq 'success') { return [PSCustomObject]@{ Country = $r.country; Code = $r.countryCode } }
    } catch { }
    return $null
}

# Map a country code to the nearest sensible Vercel region.
function Get-RegionForCountry {
    param([string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $null }
    $map = @{
        'DE'='fra1';'AT'='fra1';'CH'='fra1';'NL'='fra1';'PL'='fra1';'CZ'='fra1';'BE'='fra1';'LU'='fra1';'DK'='fra1';'HU'='fra1';
        'FR'='cdg1';'ES'='cdg1';'PT'='cdg1';'IT'='cdg1';
        'GB'='lhr1';'IE'='dub1';
        'SE'='arn1';'NO'='arn1';'FI'='arn1';'EE'='arn1';'LV'='arn1';'LT'='arn1';
        'US'='iad1';'CA'='yul1';
        'AE'='dxb1';'SA'='dxb1';'QA'='dxb1';'KW'='dxb1';'BH'='dxb1';'OM'='dxb1';'IR'='dxb1';'IQ'='dxb1';'TR'='dxb1';
        'IN'='bom1';'PK'='bom1';'BD'='bom1';
        'SG'='sin1';'MY'='sin1';'ID'='sin1';'TH'='sin1';'VN'='sin1';'PH'='sin1';
        'HK'='hkg1';'JP'='hnd1';'KR'='icn1';
        'AU'='syd1';'NZ'='syd1';
        'BR'='gru1';'AR'='gru1';'CL'='gru1';
        'ZA'='cpt1'
    }
    $c = $Code.ToUpper()
    if ($map.ContainsKey($c)) { return $map[$c] }
    return $null
}

function Get-RegionCatalog {
    return @(
        [PSCustomObject]@{ code='cdg1'; city='Paris, France';          aws='eu-west-3' },
        [PSCustomObject]@{ code='arn1'; city='Stockholm, Sweden';      aws='eu-north-1' },
        [PSCustomObject]@{ code='dub1'; city='Dublin, Ireland';        aws='eu-west-1' },
        [PSCustomObject]@{ code='lhr1'; city='London, United Kingdom'; aws='eu-west-2' },
        [PSCustomObject]@{ code='fra1'; city='Frankfurt, Germany';     aws='eu-central-1' },
        [PSCustomObject]@{ code='iad1'; city='Washington, D.C., USA';  aws='us-east-1' },
        [PSCustomObject]@{ code='dxb1'; city='Dubai, UAE';             aws='me-central-1' }
    )
}

# Friendly city name for any Vercel region code (full set, for x-vercel-id decode).
function Get-RegionCity {
    param([string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $null }
    $map = @{
        'arn1'='Stockholm, Sweden';     'bom1'='Mumbai, India';        'cdg1'='Paris, France'
        'cle1'='Cleveland, USA';        'cpt1'='Cape Town, South Africa';'dub1'='Dublin, Ireland'
        'dxb1'='Dubai, UAE';            'fra1'='Frankfurt, Germany';   'gru1'='Sao Paulo, Brazil'
        'hkg1'='Hong Kong';             'hnd1'='Tokyo, Japan';         'iad1'='Washington, D.C., USA'
        'icn1'='Seoul, South Korea';    'kix1'='Osaka, Japan';         'lhr1'='London, United Kingdom'
        'pdx1'='Portland, USA';         'sfo1'='San Francisco, USA';   'sin1'='Singapore'
        'syd1'='Sydney, Australia';     'yul1'='Montreal, Canada'
    }
    $c = $Code.Trim().ToLower()
    if ($map.ContainsKey($c)) { return $map[$c] }
    return $null
}

# Normalize a region collection for comparisons without depending on input order
# or casing. Vercel returns deployment regions as an array, while older responses
# may expose a single value.
function Get-NormalizedRegions {
    param([object]$Regions)
    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Regions)) {
        if ($null -eq $value) { continue }
        foreach ($part in ([string]$value -split ',')) {
            $code = $part.Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($code)) { [void]$normalized.Add($code) }
        }
    }
    return @($normalized | Sort-Object -Unique)
}

# Compare the requested regions with the regions reported by the finished
# deployment. The result distinguishes "not reported" from a real mismatch so
# an older/incomplete API response produces a warning instead of a false failure.
function Compare-DeploymentRegions {
    param([object]$Requested, [object]$Actual)
    $wanted = @(Get-NormalizedRegions $Requested)
    $got    = @(Get-NormalizedRegions $Actual)
    $canVerify = ($wanted.Count -gt 0 -and $got.Count -gt 0)
    $matches = $false
    if ($canVerify -and $wanted.Count -eq $got.Count) {
        $matches = $true
        for ($i = 0; $i -lt $wanted.Count; $i++) {
            if ($wanted[$i] -cne $got[$i]) { $matches = $false; break }
        }
    }
    return [PSCustomObject]@{
        Requested = @($wanted)
        Actual    = @($got)
        CanVerify = $canVerify
        Matches   = $matches
    }
}

# Decode edge ingress and function compute separately from x-vercel-id.
# Node responses normally use "<edge>::<compute>::<request-id>". A single
# region code proves only where the edge/platform response was handled (for
# example an SSO redirect), so it must not be presented as the compute region.
function Resolve-VercelRegions {
    param([string]$VercelId)
    if ([string]::IsNullOrWhiteSpace($VercelId)) { return $null }
    $parts = @($VercelId -split '::')
    $codes = @()
    # The final segment is always the request id. Excluding it avoids treating a
    # coincidentally region-shaped id as function compute.
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $p = $parts[$i].Trim().ToLowerInvariant()
        if ($p -match '^[a-z]{3}[0-9]$') {
            $codes += [PSCustomObject]@{ Code = $p; City = (Get-RegionCity $p) }
        }
    }
    if ($codes.Count -eq 0) { return $null }
    $edge = $codes[0]
    $compute = if ($codes.Count -ge 2) { $codes[$codes.Count - 1] } else { $null }
    return [PSCustomObject]@{
        Edge             = $edge
        Compute          = $compute
        Codes            = @($codes)
        ComputeAmbiguous = ($null -eq $compute)
        Raw              = $VercelId
    }
}

# Backward-compatible single-region helper. Prefer the function-compute region;
# fall back to the only edge region for callers that merely need a location.
function Resolve-VercelRegion {
    param([string]$VercelId)
    $decoded = Resolve-VercelRegions $VercelId
    if (-not $decoded) { return $null }
    $region = if ($decoded.Compute) { $decoded.Compute } else { $decoded.Edge }
    return [PSCustomObject]@{
        Code = $region.Code
        City = $region.City
        Raw  = $VercelId
        Role = if ($decoded.Compute) { 'compute' } else { 'edge' }
    }
}

# Interactive region picker. Returns an array of valid Vercel region codes.
function Select-FunctionRegions {
    param([string]$BackendUrl)

    $suggested = $null
    $hostName = Get-HostFromUrl $BackendUrl
    if ($hostName) {
        $ips = Resolve-HostIps $hostName
        if ($ips.Count -gt 0) {
            $ip = $ips[0]
            Write-Info ("Auto hint: DNS A records for '{0}' => {1}" -f $hostName, ($ips -join ', '))
            $geo = Get-IpCountry $ip
            if ($geo) {
                $suggested = Get-RegionForCountry $geo.Code
                if ($suggested) { Write-Info ("Auto hint: using IP {0} ({1}) -> suggested region '{2}'." -f $ip, $geo.Country, $suggested) }
                else { Write-Info ("Auto hint: IP {0} ({1}) has no direct region mapping." -f $ip, $geo.Country) }
            } else {
                Write-Info ("Auto hint: could not geo-locate {0} (skipping region suggestion)." -f $ip)
            }
        } else {
            Write-Info ("Auto hint: could not resolve DNS for '{0}'." -f $hostName)
        }
    }

    $catalog = @(Get-RegionCatalog)
    if ($suggested -and -not ($catalog.code -contains $suggested)) {
        $catalog += [PSCustomObject]@{ code=$suggested; city='(closest match)'; aws='' }
    }
    if (-not $suggested) { $suggested = 'iad1' }  # Vercel's default region

    Write-Host ""
    Write-Host "Choose Vercel Function Region(s). Enter numbers/codes separated by commas." -ForegroundColor Cyan
    for ($i = 0; $i -lt $catalog.Count; $i++) {
        $r = $catalog[$i]
        $tag = if ($r.code -eq $suggested) { ' (suggested)' } else { '' }
        Write-Host ("[{0}] {1} - {2} - {3}{4}" -f ($i + 1), $r.city, $r.aws, $r.code, $tag)
    }
    Write-Host "[C] Custom region code(s)"
    $ans = Read-Host ("Select region(s) [{0}]" -f $suggested)

    if ([string]::IsNullOrWhiteSpace($ans)) { return @($suggested) }

    $picked = New-Object System.Collections.Generic.List[string]
    foreach ($tokenRaw in ($ans -split ',')) {
        $token = $tokenRaw.Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        if ($token -ieq 'C') {
            $custom = Read-Host "Enter custom region code(s), comma-separated (e.g. sfo1,sin1)"
            foreach ($cRaw in ($custom -split ',')) {
                $c = $cRaw.Trim().ToLower()
                if ($script:AllRegionCodes -contains $c) { [void]$picked.Add($c) }
                elseif ($c) { Write-Warn ("Ignoring unknown region code '{0}'." -f $c) }
            }
            continue
        }
        $num = 0
        if ([int]::TryParse($token, [ref]$num) -and $num -ge 1 -and $num -le $catalog.Count) {
            [void]$picked.Add($catalog[$num - 1].code)
        } else {
            $c = $token.ToLower()
            if ($script:AllRegionCodes -contains $c) { [void]$picked.Add($c) }
            else { Write-Warn ("Ignoring invalid selection '{0}'." -f $token) }
        }
    }
    $result = @($picked | Select-Object -Unique)
    if ($result.Count -eq 0) { Write-Warn "No valid region selected; using suggested."; return @($suggested) }
    return $result
}

# ----------------------------------------------------------------------------
# Inline relay project files (no external npm dependencies)
# ----------------------------------------------------------------------------
function Get-PackageJson {
    return @'
{
  "name": "xhttp-relay",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "Authorized transparent HTTPS streaming relay (reverse proxy) on Vercel.",
  "engines": {
    "node": ">=18.x"
  }
}
'@
}

function Get-VercelJson {
    param([int]$MaxDuration = 300, [string[]]$Regions = @())
    $tmpl = @'
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
__REGIONS__  "functions": {
    "api/relay.js": {
      "maxDuration": __MAXDURATION__
    }
  },
  "rewrites": [
    { "source": "/(.*)", "destination": "/api/relay" }
  ]
}
'@
    $regionLine = ''
    if ($Regions -and @($Regions).Count -gt 0) {
        $list = (@($Regions) | ForEach-Object { '"' + $_ + '"' }) -join ', '
        $regionLine = '  "regions": [' + $list + '],' + "`n"
    }
    return $tmpl.Replace('__REGIONS__', $regionLine).Replace('__MAXDURATION__', [string]$MaxDuration)
}

# Rewrite-mode ("edge proxy") vercel.json: NO Node serverless function at all.
# Vercel's edge network reverse-proxies every request straight to the backend as an
# external-origin rewrite ( https://vercel.com/docs/routing/rewrites ). The backend
# origin is baked in at deploy time. We also disable Vercel's default CDN caching of
# external rewrites (x-vercel-enable-rewrite-caching = 0) so the tunnel is never cached.
function Get-VercelJsonRewrite {
    param([Parameter(Mandatory)][string]$BackendUrl)
    # Normalize to the origin only (scheme://host[:port]) - drop any path/query/slash.
    $origin = $BackendUrl.Trim()
    if ($origin -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $origin = 'https://' + $origin }
    try {
        $u = [System.Uri]$origin
        $origin = $u.GetLeftPart([System.UriPartial]::Authority)   # scheme://host:port
    } catch {
        $origin = $origin.TrimEnd('/')
    }
    $tmpl = @'
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "rewrites": [
    { "source": "/(.*)", "destination": "__ORIGIN__/$1" }
  ],
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        { "key": "x-vercel-enable-rewrite-caching", "value": "0" },
        { "key": "Cache-Control", "value": "no-store, no-cache, must-revalidate, max-age=0" },
        { "key": "CDN-Cache-Control", "value": "no-store" },
        { "key": "Vercel-CDN-Cache-Control", "value": "no-store" }
      ]
    }
  ]
}
'@
    return $tmpl.Replace('__ORIGIN__', $origin)
}

function Get-RelayJs {
    return @'
// api/relay.js
// Authorized transparent HTTPS streaming relay (reverse proxy) for Vercel.
//
// Data path:
//   Client -> Vercel project URL (443) -> this function -> backend (HTTPS) -> back to client
//
// The relay does NOT inspect, decode, or modify the application payload. It only
// forwards the request method, headers, body stream, and sub-path to the backend,
// then streams the backend response back without buffering it in memory.
//
// Configuration (Vercel environment variables):
//   BACKEND_URL    e.g. https://backend.example.com:8443  (origin only)
//   ALLOW_INSECURE 0 or 1   (1 = do not verify the backend TLS certificate; for self-signed)
//
// The request path is forwarded to the backend UNCHANGED, so the client path and your
// backend (3x-ui / Xray) inbound path are the same single value - no rewriting.

import https from 'node:https';
import http from 'node:http';
import { URL } from 'node:url';

// Disable Vercel's automatic body parsing so the raw request body can stream through.
export const config = {
  api: { bodyParser: false },
};

function getConfig() {
  return {
    backendUrl:    process.env.BACKEND_URL || '',
    allowInsecure: ['1', 'true', 'yes'].includes(String(process.env.ALLOW_INSECURE || '').toLowerCase()),
  };
}

export default function handler(req, res) {
  const cfg = getConfig();

  if (!cfg.backendUrl) {
    res.statusCode = 500;
    res.setHeader('content-type', 'text/plain; charset=utf-8');
    res.end('Relay misconfigured: BACKEND_URL is not set.');
    return;
  }

  let backend;
  try {
    backend = new URL(cfg.backendUrl);
  } catch {
    res.statusCode = 500;
    res.setHeader('content-type', 'text/plain; charset=utf-8');
    res.end('Relay misconfigured: BACKEND_URL is invalid.');
    return;
  }

  const isHttps = backend.protocol === 'https:';
  const client  = isHttps ? https : http;
  const port    = backend.port ? Number(backend.port) : (isHttps ? 443 : 80);
  // Pure passthrough: forward the original path + query unchanged to the backend.
  let targetPath = req.url || '/';
  if (!targetPath.startsWith('/')) targetPath = '/' + targetPath;

  // Clone and sanitize headers. Remove ones that break streaming/forwarding.
  const headers = { ...req.headers };
  delete headers['host'];            // let the client set the backend Host automatically
  delete headers['accept-encoding']; // request identity encoding to keep the stream clean
  delete headers['connection'];
  delete headers['keep-alive'];
  delete headers['proxy-connection'];

  const options = {
    protocol: backend.protocol,
    hostname: backend.hostname,
    port,
    method:   req.method,
    path:     targetPath,
    headers,
  };
  if (isHttps) {
    options.servername = backend.hostname;          // TLS SNI = backend hostname
    options.rejectUnauthorized = !cfg.allowInsecure; // honor ALLOW_INSECURE
  }

  const proxyReq = client.request(options, (proxyRes) => {
    const respHeaders = { ...proxyRes.headers };
    respHeaders['x-accel-buffering'] = 'no'; // hint intermediaries not to buffer
    res.writeHead(proxyRes.statusCode || 502, respHeaders);
    proxyRes.pipe(res); // stream the backend response straight to the client
    proxyRes.on('error', () => { try { res.end(); } catch {} });
  });

  proxyReq.on('error', () => {
    if (!res.headersSent) {
      res.statusCode = 502;
      res.setHeader('content-type', 'text/plain; charset=utf-8');
      res.end('502 Bad Gateway: backend connection failed.');
    } else {
      try { res.end(); } catch {}
    }
  });

  // Tear down the upstream request if the client disconnects.
  req.on('aborted', () => { try { proxyReq.destroy(); } catch {} });
  res.on('close',   () => { try { proxyReq.destroy(); } catch {} });

  // Forward the request body by streaming it (no full-body buffering).
  const method = (req.method || 'GET').toUpperCase();
  if (method === 'GET' || method === 'HEAD') {
    proxyReq.end();
  } else if (req.readableEnded && req.body !== undefined && req.body !== null) {
    // Fallback: if the runtime already consumed/parsed the body, forward it directly.
    const b = req.body;
    if (Buffer.isBuffer(b) || typeof b === 'string') proxyReq.end(b);
    else proxyReq.end(JSON.stringify(b));
  } else {
    req.pipe(proxyReq);
  }
}
'@
}

# ----------------------------------------------------------------------------
# Local copy of the deployed files + post-deploy health check
# ----------------------------------------------------------------------------
# Write the EXACT files that were just deployed to a local folder so the user can
# inspect / version / re-use them. BOM-free UTF-8 to match the inline upload.
function Save-DeployedFiles {
    param([string]$ProjectName, [string]$Pkg, [string]$VercelJson, [string]$RelayJs)
    try {
        $safe = ($ProjectName -replace '[^a-zA-Z0-9._-]', '_')
        $root = Join-Path $script:ScriptDir (Join-Path 'projects' $safe)
        if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        $enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8, no BOM
        # Only write the files that this build actually uploads. The rewrite build
        # ships vercel.json alone (no package.json / api/relay.js). LF-normalized so
        # the local copy is byte-identical to what was deployed.
        if ($VercelJson) { [IO.File]::WriteAllText((Join-Path $root 'vercel.json'), (ConvertTo-Lf $VercelJson), $enc) }
        if ($Pkg)        { [IO.File]::WriteAllText((Join-Path $root 'package.json'), (ConvertTo-Lf $Pkg), $enc) }
        if ($RelayJs) {
            $api = Join-Path $root 'api'
            if (-not (Test-Path $api)) { New-Item -ItemType Directory -Path $api -Force | Out-Null }
            [IO.File]::WriteAllText((Join-Path $api 'relay.js'), (ConvertTo-Lf $RelayJs), $enc)
        }
        Write-Info ("Saved a local copy of the deployed files to: {0}" -f $root)
        Add-LogLine ("local files saved: {0}" -f $root)
    } catch {
        Write-Warn ("Could not save local files: {0}" -f $_.Exception.Message)
    }
}

# Single HTTP GET that returns the status code even on 4xx/5xx (PS 5.1 + 7 safe).
function Invoke-HttpProbe {
    param([string]$Url, [int]$TimeoutSec = 15)
    $r = [PSCustomObject]@{
        Status      = 0
        Reached     = $false
        VercelId    = $null
        VercelError = $null
        VercelCache = $null
        Location    = $null
        Error       = $null
    }
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'xhttp-relay-healthcheck'
        try {
            $resp = $req.GetResponse()
            $r.Status = [int]$resp.StatusCode
            $r.VercelId = $resp.Headers['x-vercel-id']
            $r.VercelError = $resp.Headers['x-vercel-error']
            $r.VercelCache = $resp.Headers['x-vercel-cache']
            $r.Location = $resp.Headers['location']
            $r.Reached = $true
            $resp.Close()
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) {
                $er = $_.Exception.Response
                $r.Status = [int]$er.StatusCode
                $r.VercelId = $er.Headers['x-vercel-id']
                $r.VercelError = $er.Headers['x-vercel-error']
                $r.VercelCache = $er.Headers['x-vercel-cache']
                $r.Location = $er.Headers['location']
                $r.Reached = $true          # an HTTP response (even an error) still proves reachability
                $er.Close()
            } else {
                $r.Error = $_.Exception.Message
            }
        }
    } catch {
        $r.Error = $_.Exception.Message
    }
    return $r
}

# Explain, then (optionally) run a one-shot health check against the relay URL.
function Invoke-HealthCheck {
    param([string]$PublicHost, [object]$ExpectedRegions = $null)
    if ([string]::IsNullOrWhiteSpace($PublicHost)) { return }
    $PublicHost = $PublicHost.Replace('https://','').Replace('http://','').TrimEnd('/')

    Write-Title "Health Check"
    Write-Host "A health check sends ONE harmless GET to your relay's public URL and reads the"
    Write-Host "HTTP/platform headers, so you know the deploy actually works before pointing clients at it:" -ForegroundColor Gray
    Write-Host "  - HTTP 2xx/4xx without a Vercel platform error = relay reached your backend." -ForegroundColor Gray
    Write-Host "  - 502 Bad Gateway = relay is up, but the backend is unreachable" -ForegroundColor Gray
    Write-Host "      (check BACKEND_URL host/port, firewall, or set ALLOW_INSECURE=1 for self-signed TLS)." -ForegroundColor Gray
    Write-Host "  - 500 / FUNCTION_INVOCATION_FAILED = the function crashed (check env vars)." -ForegroundColor Gray
    Write-Host "  - No response / timeout = DNS not propagated yet or a cold start; retry shortly." -ForegroundColor Gray
    Write-Host ""
    $url = "https://$PublicHost/"
    if (-not (Read-YesNo "Run a health check now?" $true)) {
        Write-Info ("Tip: you can test it any time with:  curl -i {0}" -f $url)
        return
    }

    Write-Info ("Probing {0} ..." -f $url)
    $res = Invoke-HttpProbe -Url $url -TimeoutSec 20
    Add-LogLine ("healthcheck GET {0} -> status={1} reached={2} vercel-id={3} vercel-error={4} cache={5} location={6} err={7}" -f `
        $url, $res.Status, $res.Reached, $res.VercelId, $res.VercelError, `
        $res.VercelCache, $res.Location, $res.Error)

    if ($res.Reached) {
        if ($res.VercelId) {
            $decoded = Resolve-VercelRegions $res.VercelId
            if ($decoded) {
                $edgeWhere = if ($decoded.Edge.City) {
                    ("{0} ({1})" -f $decoded.Edge.Code, $decoded.Edge.City)
                } else { $decoded.Edge.Code }
                Write-Host ("  Edge ingress:     {0}" -f $edgeWhere) -ForegroundColor DarkGray
                Add-LogLine ("healthcheck edge-region={0} ({1})" -f $decoded.Edge.Code, $decoded.Edge.City)

                if ($decoded.Compute) {
                    $computeWhere = if ($decoded.Compute.City) {
                        ("{0} ({1})" -f $decoded.Compute.Code, $decoded.Compute.City)
                    } else { $decoded.Compute.Code }
                    Write-Host ("  Function compute: {0}" -f $computeWhere) -ForegroundColor DarkGray
                    Add-LogLine ("healthcheck compute-region={0} ({1})" -f $decoded.Compute.Code, $decoded.Compute.City)

                    $expected = @(Get-NormalizedRegions $ExpectedRegions)
                    if ($expected.Count -gt 0) {
                        if ($expected -contains $decoded.Compute.Code) {
                            Write-Ok ("Live function region matches the requested region set ({0})." -f ($expected -join ', '))
                        } else {
                            Write-Err ("Live function region mismatch: requested [{0}], observed '{1}'." -f `
                                ($expected -join ', '), $decoded.Compute.Code)
                        }
                    }
                } else {
                    Write-Host "  Function compute: not present in this response (edge/platform response only)." -ForegroundColor DarkGray
                    Add-LogLine "healthcheck compute-region=unavailable (single-region x-vercel-id)" 'WARN'
                }
            } else {
                Write-Host ("  x-vercel-id: {0}" -f $res.VercelId) -ForegroundColor DarkGray
            }
        }

        if ($res.VercelError) {
            Write-Err ("Vercel platform error: {0} (HTTP {1})." -f $res.VercelError, $res.Status)
            Write-Host "  This response did not prove that the relay reached your backend." -ForegroundColor Gray
            return
        }
        if ($res.Status -ge 300 -and $res.Status -lt 400) {
            Write-Warn ("HTTP {0} redirect - the relay was not executed." -f $res.Status)
            if ($res.Location) { Write-Host ("  Redirect: {0}" -f $res.Location) -ForegroundColor Gray }
            return
        }
        switch ($res.Status) {
            502 {
                Write-Warn ("HTTP 502 - relay is UP but the backend did not answer.")
                Write-Host  "  Hint: verify BACKEND_URL host/port is reachable from the public internet;" -ForegroundColor Gray
                Write-Host  "        for a self-signed backend cert set ALLOW_INSECURE=1 and redeploy." -ForegroundColor Gray
            }
            500 {
                Write-Warn ("HTTP 500 - the function may have crashed. Check env vars / the deploy log.")
            }
            default {
                Write-Ok ("HTTP {0} - relay is LIVE and forwarding to the backend." -f $res.Status)
                Write-Host  "  (4xx/404 here is normal: a plain GET is not a real client handshake.)" -ForegroundColor Gray
            }
        }
    } else {
        Write-Warn ("No HTTP response: {0}" -f ($res.Error))
        Write-Host  "  Hint: DNS may still be propagating, or it was a cold start. Wait ~30s and retry," -ForegroundColor Gray
        Write-Host ("        or test manually:  curl -i {0}" -f $url) -ForegroundColor Gray
    }
}

# ----------------------------------------------------------------------------
# Deployment (inline files via v13 deployments API)
# ----------------------------------------------------------------------------
# Fetch build events into the log; optionally surface error lines to the console.
function Get-AndLogDeploymentEvents {
    param([string]$DepId, [bool]$ShowErrors = $false)
    if (-not $DepId) { return }
    $ev = Invoke-VercelApi -Method 'GET' -Path "/v3/deployments/$DepId/events" `
        -Query @{ builds = '1'; direction = 'forward'; limit = '1000' }
    if (-not $ev) { Add-LogLine "No build events returned." ; return }

    Add-LogLine "---- build events ----"
    $errorLines = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($ev)) {
        $txt = if ($e.text) { $e.text } elseif ($e.payload -and $e.payload.text) { $e.payload.text } else { $null }
        if ([string]::IsNullOrEmpty($txt)) { continue }
        $type  = if ($e.type) { $e.type } else { '' }
        $level = if ($e.level) { $e.level } else { '' }
        foreach ($line in ($txt -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $tag = if ($level) { "$type/$level" } else { $type }
            Add-LogLine ("    [{0}] {1}" -f $tag, $line) 'BUILD'
            if ($level -eq 'error' -or $type -eq 'stderr' -or $type -eq 'fatal' -or
                $line -match '(?i)error|failed|invalid|exceeded|cannot|not allowed') {
                $errorLines.Add($line)
            }
        }
    }
    Add-LogLine "---- end build events ----"

    if ($ShowErrors -and $errorLines.Count -gt 0) {
        Write-Host ""
        Write-Err "Build error/diagnostic lines (also in the log file):"
        foreach ($l in ($errorLines | Select-Object -Last 25)) { Write-Host ("  $l") -ForegroundColor Red }
    }
}

# Prompt for maxDuration with a plan-aware suggested default. Returns an int.
function Get-MaxDurationInteractive {
    $suggestedMd = Get-SuggestedMaxDuration
    $planLabel = Format-PlanLabel -Plan $script:ScopePlan `
        -BillingStatus $script:ScopeBillingStatus -Blocked $script:ScopeBlocked
    Write-Info ("Deployment-scope plan: {0}. Suggested safe maxDuration: {1}s." -f $planLabel, $suggestedMd)
    Write-Info "Fluid compute (default on new projects) allows higher: Hobby up to 300, Pro up to 800."
    $raw = Read-Host ("maxDuration in seconds [{0}]" -f $suggestedMd)
    [int]$md = $suggestedMd
    if (-not [string]::IsNullOrWhiteSpace($raw)) { [void][int]::TryParse($raw.Trim(), [ref]$md) }
    if ($md -lt 1) { $md = $suggestedMd }
    Write-Info ("Using maxDuration = {0}s" -f $md)
    return $md
}

# Region picker with plan-aware limits. Hobby supports one configurable region;
# Pro and Enterprise can select multiple regions (subject to Vercel's plan limit).
function Select-DeployRegions {
    param([string]$BackendUrl)
    $regions = @(Select-FunctionRegions -BackendUrl $BackendUrl)
    if ($script:ScopePlan -eq 'hobby' -and $regions.Count -gt 1) {
        Write-Warn ("Hobby supports one Function region. Using the first selection: {0}." -f $regions[0])
        $regions = @($regions[0])
    }
    Write-Info ("Selected region(s): {0}" -f ($regions -join ', '))
    return $regions
}

# Ask which build to deploy. Returns 'node' or 'rewrite'.
#   node    = the original api/relay.js serverless function (most compatible).
#   rewrite = a function-less vercel.json that makes Vercel's edge proxy straight
#             to the backend (no compute), but needs a valid public TLS cert.
function Read-BuildMode {
    param([string]$Default = 'node')
    Write-Title "Build type"
    Write-Host "Two ways to run the relay on Vercel:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [1] Node function" -ForegroundColor Cyan -NoNewline
    Write-Host "  (api/relay.js serverless function)" -ForegroundColor DarkGray
    Write-Host "      + Works with self-signed backend certs (ALLOW_INSECURE)." -ForegroundColor Gray
    Write-Host "      + Backend URL is a runtime env var - change it without re-uploading code." -ForegroundColor Gray
    Write-Host "      - Uses compute; Hobby supports one selected region and has a maxDuration cap." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [2] Rewrite / edge proxy" -ForegroundColor Cyan -NoNewline
    Write-Host "  (vercel.json only, no Node)" -ForegroundColor DarkGray
    Write-Host "      + No serverless function: no cold starts, no maxDuration limit, no compute." -ForegroundColor Gray
    Write-Host "      + Served from Vercel's global edge rather than one selected Function region." -ForegroundColor Gray
    Write-Host "      - Backend MUST present a VALID, publicly-trusted TLS certificate;" -ForegroundColor Yellow
    Write-Host "        self-signed certs will NOT work (no insecure option at the edge)." -ForegroundColor Yellow
    Write-Host "      - Backend URL is baked into vercel.json (changing it needs a redeploy)." -ForegroundColor Gray
    Write-Host ""
    $def = if ($Default -eq 'rewrite') { '2' } else { '1' }
    $ans = (Read-Host ("Choose build  [1=Node, 2=Rewrite]  [{0}]" -f $def)).Trim()
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $def }
    if ($ans -eq '2') { return 'rewrite' }
    return 'node'
}

function Deploy-Relay {
    param(
        [string] $BackendUrl,
        [int]    $MaxDuration = 0,      # >0 = use as-is (pre-collected); 0 = ask interactively
        [object] $Regions     = $null,  # non-null = use as-is (pre-collected); null = ask
        [string] $Mode        = ''      # 'node' | 'rewrite'; '' = ask interactively
    )
    if (-not (Ensure-Project)) { return }

    Start-DeployLog -ProjectName $script:SelectedProject.name

    if ([string]::IsNullOrWhiteSpace($BackendUrl)) { $BackendUrl = $script:SelectedProject.backendUrl }

    # Pick the build (Node function vs. edge rewrite) unless the caller pre-selected it.
    if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = Read-BuildMode }
    if ($Mode -ne 'rewrite') { $Mode = 'node' }
    Add-LogLine ("build mode: {0}" -f $Mode)

    if ($Mode -eq 'rewrite') {
        # ----- Rewrite / edge-proxy build: vercel.json only, no function -----
        # The backend origin is baked into vercel.json, so a valid URL is REQUIRED here.
        if ([string]::IsNullOrWhiteSpace($BackendUrl)) { $BackendUrl = Get-CurrentBackendUrl }
        while ([string]::IsNullOrWhiteSpace($BackendUrl) -or -not (Test-BackendUrl $BackendUrl)) {
            if (-not [string]::IsNullOrWhiteSpace($BackendUrl)) { Write-Warn "Stored backend URL is invalid; re-enter it." }
            $BackendUrl = (Read-Host "Backend URL to proxy to (e.g. https://backend.example.com:8443)").Trim()
        }
        $script:SelectedProject.backendUrl = $BackendUrl   # cache for redeploys/templates
        Write-Warn "Rewrite mode requires a VALID public TLS certificate on the backend."
        Write-Warn "Self-signed certs will fail at the edge - use the Node build for those."

        $vj = Get-VercelJsonRewrite -BackendUrl $BackendUrl
        Write-LogBlock -Title 'vercel.json (rewrite)' -Content $vj
        Add-LogLine ("files: vercel.json ({0} B) [edge rewrite -> {1}, no function]" -f $vj.Length, $BackendUrl)

        # Keep a local, BOM-free copy of exactly what is being uploaded.
        Save-DeployedFiles -ProjectName $script:SelectedProject.name -VercelJson $vj

        $files = @(
            [ordered]@{ file = 'vercel.json'; data = (ConvertTo-Base64Utf8 $vj); encoding = 'base64' }
        )
        Add-LogLine ("POST /v13/deployments project={0} target=production mode=rewrite" -f `
            $script:SelectedProject.name) 'INFO'
    } else {
        # ----- Node function build (original): package.json + vercel.json + api/relay.js -----
        # Backend URL is used only for the region auto-hint (not required to deploy).
        if (($null -eq $Regions) -and [string]::IsNullOrWhiteSpace($BackendUrl)) {
            $ans = Read-Host "Backend host/URL for region auto-hint (optional, Enter to skip)"
            if (-not [string]::IsNullOrWhiteSpace($ans)) {
                if ($ans -notmatch '^[a-zA-Z]+://') { $ans = 'https://' + $ans }
                $BackendUrl = $ans
            }
        }

        # maxDuration + regions: use pre-collected values when supplied (guided flow),
        # otherwise prompt interactively (standalone redeploy).
        if ($MaxDuration -gt 0) { [int]$md = $MaxDuration; Write-Info ("Using maxDuration = {0}s" -f $md) }
        else                    { [int]$md = Get-MaxDurationInteractive }

        if ($null -ne $Regions) { $regions = @($Regions); Write-Info ("Region(s): {0}" -f ($regions -join ', ')) }
        else                    { $regions = @(Select-DeployRegions -BackendUrl $BackendUrl) }
        if ($script:ScopePlan -eq 'hobby' -and $regions.Count -gt 1) {
            Write-Warn ("Hobby supports one Function region. Using the first selection: {0}." -f $regions[0])
            $regions = @($regions[0])
        }

        $pkg   = Get-PackageJson
        $vj    = Get-VercelJson -MaxDuration $md -Regions $regions
        $relay = Get-RelayJs

        Write-LogBlock -Title 'vercel.json' -Content $vj
        Add-LogLine ("files: package.json ({0} B), vercel.json ({1} B), api/relay.js ({2} B)" -f `
            $pkg.Length, $vj.Length, $relay.Length)

        # Keep a local, BOM-free copy of exactly what is being uploaded.
        Save-DeployedFiles -ProjectName $script:SelectedProject.name -Pkg $pkg -VercelJson $vj -RelayJs $relay

        # Inline files are base64-encoded to avoid any JSON-escaping issues.
        $files = @(
            [ordered]@{ file = 'package.json'; data = (ConvertTo-Base64Utf8 $pkg);   encoding = 'base64' },
            [ordered]@{ file = 'vercel.json';  data = (ConvertTo-Base64Utf8 $vj);    encoding = 'base64' },
            [ordered]@{ file = 'api/relay.js'; data = (ConvertTo-Base64Utf8 $relay); encoding = 'base64' }
        )
        Add-LogLine ("POST /v13/deployments project={0} target=production mode=node maxDuration={1} regions=[{2}]" -f `
            $script:SelectedProject.name, $md, ($regions -join ',')) 'INFO'
    }

    $body = [ordered]@{
        name            = $script:SelectedProject.name
        project         = $script:SelectedProject.id
        target          = 'production'
        files           = $files
        projectSettings = [ordered]@{ framework = $null }  # "Other" - no framework preset
    }
    # Match Vercel CLI behavior: for source/inline deployments, regions must also
    # be sent as a top-level deployment option. Keeping the same value in
    # vercel.json makes the source self-describing, while this explicit field
    # prevents the REST deployment from silently inheriting the project's iad1
    # default (the bug caught by a live deployment audit).
    if ($Mode -eq 'node' -and @($regions).Count -gt 0) {
        $body['regions'] = @($regions)
        Add-LogLine ("deployment payload regions=[{0}]" -f ($regions -join ','))
    }

    Write-Info "Creating production deployment with inline files..."
    $res = Invoke-VercelApi -Method 'POST' -Path '/v13/deployments' -Body $body
    if (-not $res) { Write-Err "Deployment request failed."; Stop-DeployLog; return }

    $depId = $res.id
    $url   = $res.url
    Write-Ok "Deployment created; building..."
    Add-LogLine ("deployment id={0} url=https://{1}" -f $depId, $url)

    $finalState = $null
    $finalDeployment = $null
    if ($depId) {
        # Animated build wait: poll the API every few seconds while spinning a
        # frame in place so it feels live (the long per-deploy URL stays in the log).
        $frames   = $script:Spinner
        $fi       = 0
        $start    = Get-Date
        $deadline = $start.AddMinutes(6)
        $nextPoll = $start
        $state    = 'QUEUED'
        $lastLogged = ''
        while ((Get-Date) -lt $deadline) {
            if ((Get-Date) -ge $nextPoll) {
                $st = Invoke-VercelApi -Method 'GET' -Path "/v13/deployments/$depId"
                if (-not $st) { break }
                $state = if ($st.readyState) { $st.readyState } else { $st.status }
                if ($state -ne $lastLogged) { Add-LogLine ("state: {0}" -f $state); $lastLogged = $state }
                if ($state -in @('READY', 'ERROR', 'CANCELED')) {
                    $finalState = $state
                    $finalDeployment = $st
                    if ($st.errorMessage) { Add-LogLine ("errorMessage: {0}" -f $st.errorMessage) 'ERROR' }
                    if ($st.errorCode)    { Add-LogLine ("errorCode: {0}" -f $st.errorCode) 'ERROR' }
                    break
                }
                $nextPoll = (Get-Date).AddSeconds(3)
            }
            $elapsed = [int]((Get-Date) - $start).TotalSeconds
            Write-Host ("`r  {0}  building {1,-9} {2,3}s   " -f $frames[$fi % $frames.Count], $state.ToLower(), $elapsed) `
                -ForegroundColor Cyan -NoNewline
            $fi++
            Start-Sleep -Milliseconds 110
        }
        Write-Host ("`r" + (' ' * 44) + "`r") -NoNewline   # clear the spinner line
    }

    # Always capture build events to the log; show error lines if it failed.
    Get-AndLogDeploymentEvents -DepId $depId -ShowErrors:($finalState -eq 'ERROR')

    # The stable production host for the template/summary (short host, not the long URL).
    $prodHost = "$($script:SelectedProject.name).vercel.app"
    $script:SelectedProject.url = $prodHost

    $deploymentConfigOk = $true
    if ($finalState -eq 'READY') {
        Write-Ok ("Build READY in {0}s." -f ([int]((Get-Date) - $start).TotalSeconds))

        # Do not trust a successful build alone: confirm Vercel placed the Node
        # function in exactly the requested region set. The terminal poll is the
        # authoritative deployment object; fall back to the create response only
        # if a legacy API stopped polling without returning the full object.
        if ($Mode -eq 'node') {
            $regionSource = if ($finalDeployment) { $finalDeployment } else { $res }
            $regionCheck = Compare-DeploymentRegions -Requested $regions -Actual $regionSource.regions
            if (-not $regionCheck.CanVerify) {
                $deploymentConfigOk = $false
                Write-Warn ("Vercel did not report deployment regions; could not verify requested [{0}]." -f `
                    ($regionCheck.Requested -join ', '))
                Write-Host "  The build is live, but its Function region is unverified." -ForegroundColor Yellow
                Add-LogLine ("deployment region verification unavailable requested=[{0}]" -f `
                    ($regionCheck.Requested -join ',')) 'WARN'
            } elseif ($regionCheck.Matches) {
                Write-Ok ("Deployment region verified: {0}." -f ($regionCheck.Actual -join ', '))
                Add-LogLine ("deployment regions verified requested=[{0}] actual=[{1}]" -f `
                    ($regionCheck.Requested -join ','), ($regionCheck.Actual -join ',')) 'OK'
            } else {
                $deploymentConfigOk = $false
                Write-Err ("Deployment region mismatch: requested [{0}], Vercel applied [{1}]." -f `
                    ($regionCheck.Requested -join ', '), ($regionCheck.Actual -join ', '))
                Write-Host "  The build is live, but it is not considered correctly configured." -ForegroundColor Yellow
                Add-LogLine ("deployment region mismatch requested=[{0}] actual=[{1}]" -f `
                    ($regionCheck.Requested -join ','), ($regionCheck.Actual -join ',')) 'ERROR'
            }
        }

        Write-Host ""
        $readyColor = if ($deploymentConfigOk) { 'Green' } else { 'Yellow' }
        Write-Box -Color $readyColor -TextColor White -Lines @(
            ("Public URL   https://{0}" -f $prodHost)
        )
    } elseif ($finalState -eq 'ERROR') {
        Write-Err "Deployment FAILED (state: ERROR). See the build error lines above and the log file."
    } elseif ($finalState) {
        Write-Warn ("Deployment ended with state: {0}" -f $finalState)
    } else {
        Write-Warn "Build polling stopped before a final state; check the log file / Vercel dashboard."
    }

    # On success: offer a health check, then hand the user a ready-to-paste client
    # config (host + path pre-filled from this deploy; only the UUID is asked).
    if ($finalState -eq 'READY') {
        if ($Mode -eq 'node') { Invoke-HealthCheck -PublicHost $prodHost -ExpectedRegions $regions }
        else                  { Invoke-HealthCheck -PublicHost $prodHost }

        if ($deploymentConfigOk) {
            New-QuickClientConfig -PublicHost $prodHost -Path (Get-CurrentRelayPath)
        } else {
            Write-Warn "Ready-to-use client config was not generated because region verification failed."
            Write-Warn "Correct the region setting and redeploy before using this endpoint."
        }
    }

    Stop-DeployLog
}

# ----------------------------------------------------------------------------
# Custom domains
# ----------------------------------------------------------------------------
function Show-DomainStatus {
    param([string]$Domain, $Detail)
    if (-not $Detail) { return }
    Write-Title ("Domain: {0}" -f $Domain)
    if ($Detail.verified) { Write-Ok "Status: VERIFIED" } else { Write-Warn "Status: NOT verified yet" }

    if ($Detail.verification) {
        Write-Host "Add the following DNS verification record(s):" -ForegroundColor Cyan
        foreach ($v in @($Detail.verification)) {
            Write-Host ("  Type:   {0}" -f $v.type)
            Write-Host ("  Name:   {0}" -f $v.domain)
            Write-Host ("  Value:  {0}" -f $v.value)
            if ($v.reason) { Write-Host ("  Reason: {0}" -f $v.reason) }
            Write-Host ""
        }
    }
    Write-Host "Standard Vercel DNS targets (if no challenge is shown above):" -ForegroundColor DarkGray
    Write-Host "  Apex domain  (example.com):      A      @      76.76.21.21"
    Write-Host "  Subdomain    (relay.example.com): CNAME  <sub>  cname.vercel-dns.com"
}

function Add-Domain {
    if (-not (Ensure-Project)) { return }
    $domain = (Read-Host "Enter the custom domain (e.g. relay.example.com)").Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($domain)) { Write-Warn "No domain entered."; return }
    $res = Invoke-VercelApi -Method 'POST' -Path "/v10/projects/$($script:SelectedProject.id)/domains" -Body @{ name = $domain }
    if (-not $res) { return }
    Write-Ok ("Domain '{0}' added to project." -f $domain)
    Show-DomainStatus -Domain $domain -Detail $res
    Write-Info "After creating the DNS records, use menu [10] to check/verify status."
}

function Check-Domain {
    if (-not (Ensure-Project)) { return }
    $domain = (Read-Host "Enter the domain to check").Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($domain)) { return }
    $res = Invoke-VercelApi -Method 'GET' -Path "/v9/projects/$($script:SelectedProject.id)/domains/$domain"
    if (-not $res) { return }
    Show-DomainStatus -Domain $domain -Detail $res
    if (-not $res.verified) {
        if (Read-YesNo "Attempt verification now?" $true) {
            $v = Invoke-VercelApi -Method 'POST' -Path "/v9/projects/$($script:SelectedProject.id)/domains/$domain/verify"
            if ($v) { Show-DomainStatus -Domain $domain -Detail $v }
        }
    }
}

# List every domain attached to the selected project. Returns the domain array
# (also used by the remove flow). The auto-assigned *.vercel.app host is tagged.
function Show-DomainList {
    if (-not (Ensure-Project)) { return @() }
    $res = Invoke-VercelApi -Method 'GET' -Path "/v9/projects/$($script:SelectedProject.id)/domains"
    if (-not $res) { return @() }
    $domains = @($res.domains)
    Write-Title ("Domains :: {0}" -f $script:SelectedProject.name)
    if ($domains.Count -eq 0) { Write-Info "No domains attached."; return @() }
    for ($i = 0; $i -lt $domains.Count; $i++) {
        $d = $domains[$i]
        $isVercel = ($d.name -like '*.vercel.app')
        Write-Host ("  {0} " -f $script:Ui.DOT) -ForegroundColor DarkCyan -NoNewline
        Write-Host ("[{0}] " -f $i) -ForegroundColor Cyan -NoNewline
        Write-Host $d.name -ForegroundColor White -NoNewline
        if ($isVercel)        { Write-Host "  (auto Vercel host)" -ForegroundColor DarkGray }
        elseif ($d.verified)  { Write-Host ("  {0} verified" -f $script:Ui.OK) -ForegroundColor Green }
        else                  { Write-Host ("  {0} not verified" -f $script:Ui.WARN) -ForegroundColor Yellow }
    }
    return $domains
}

# Remove a custom domain from the project (the *.vercel.app host cannot be removed).
function Remove-Domain {
    if (-not (Ensure-Project)) { return }
    $domains = @(Show-DomainList)
    $removable = @($domains | Where-Object { $_.name -notlike '*.vercel.app' })
    if ($removable.Count -eq 0) { Write-Info "No removable custom domains (the Vercel host stays)."; return }
    Write-Host ""
    $sel = (Read-Host "Enter the domain number to remove").Trim()
    $idx = -1
    if (-not ([int]::TryParse($sel, [ref]$idx)) -or $idx -lt 0 -or $idx -ge $domains.Count) {
        Write-Err "Invalid selection."; return
    }
    $target = $domains[$idx]
    if ($target.name -like '*.vercel.app') {
        Write-Warn "The auto-assigned Vercel host cannot be removed."; return
    }
    if (-not (Read-YesNo ("Remove domain '{0}' from this project?" -f $target.name) $false)) {
        Write-Info "Aborted."; return
    }
    $null = Invoke-VercelApi -Method 'DELETE' -Path "/v9/projects/$($script:SelectedProject.id)/domains/$($target.name)"
    if ($script:LastApiOk) { Write-Ok ("Domain '{0}' removed." -f $target.name) }
}

# Self-paced submenu for all custom-domain operations.
function Invoke-DomainMenu {
    if (-not (Ensure-Project)) { Pause-Menu; return }
    while ($true) {
        Clear-Screen
        Write-Title ("Custom Domains :: {0}" -f $script:SelectedProject.name)
        Write-MenuItem '1' 'List domains'
        Write-MenuItem '2' 'Add a custom domain'
        Write-MenuItem '3' 'Check / verify a domain'
        Write-MenuItem '4' 'Remove a custom domain'
        Write-MenuItem '0' 'Back to main menu'
        $c = (Read-Host "  Choice").Trim()
        if ($c -eq '0') { return }
        Clear-Screen
        switch ($c) {
            '1' { [void](Show-DomainList) }
            '2' { Add-Domain }
            '3' { Check-Domain }
            '4' { Remove-Domain }
            default { Write-Warn "Unknown option." }
        }
        Pause-Menu
    }
}

# ----------------------------------------------------------------------------
# Client connection template generator (generic / configurable)
# ----------------------------------------------------------------------------
function New-ClientTemplate {
    $defaultHost = if ($script:SelectedProject) { $script:SelectedProject.url } else { '' }
    $h = Read-Host ("Public host (project URL / custom domain) [{0}]" -f $defaultHost)
    if ([string]::IsNullOrWhiteSpace($h)) { $h = $defaultHost }
    $h = $h.Trim().Replace('https://', '').Replace('http://', '').TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($h)) { Write-Err "A host is required."; return }

    $id = Read-Host "Client UUID / identifier"
    if ([string]::IsNullOrWhiteSpace($id)) { Write-Warn "No id entered; using placeholder."; $id = 'YOUR-UUID-HERE' }

    $pathDefault = if ($script:SelectedProject -and $script:SelectedProject.path) { $script:SelectedProject.path } else { '/api' }
    $path   = Format-PathValue (Read-Host ("Path (same as your inbound) [{0}]" -f $pathDefault)) $pathDefault
    $scheme = Read-Host "Protocol scheme (default: vless)"
    if ([string]::IsNullOrWhiteSpace($scheme)) { $scheme = 'vless' }
    $type   = Read-Host "Transport type label (default: xhttp)"
    if ([string]::IsNullOrWhiteSpace($type)) { $type = 'xhttp' }
    $mode   = Read-Host "xHTTP mode (default: auto)"
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'auto' }
    $fp     = Read-Host "TLS fingerprint / uTLS (default: chrome)"
    if ([string]::IsNullOrWhiteSpace($fp)) { $fp = 'chrome' }
    $name   = Read-Host "Display name (optional)"
    if ([string]::IsNullOrWhiteSpace($name)) { $name = if ($script:SelectedProject) { $script:SelectedProject.name } else { 'relay' } }

    $encPath = [uri]::EscapeDataString($path)
    $encName = [uri]::EscapeDataString($name)
    $encMode = [uri]::EscapeDataString($mode)
    $encFp   = [uri]::EscapeDataString($fp)

    # Generic URL-like client config. Host=SNI=public Vercel host, TLS on 443.
    # xHTTP transport carries mode=auto and a TLS fingerprint (fp=chrome) by default.
    $link = "$($scheme)://$($id)@$($h):443?security=tls&sni=$($h)&fp=$($encFp)&host=$($h)&type=$($type)&mode=$($encMode)&path=$($encPath)&encryption=none#$($encName)"

    Write-Title "Client Connection Template"
    Write-Host ("Host (server):   {0}" -f $h)
    Write-Host  "Port:            443"
    Write-Host  "Security:        tls"
    Write-Host ("SNI:             {0}" -f $h)
    Write-Host ("Host header:     {0}" -f $h)
    Write-Host ("Fingerprint:     {0}" -f $fp)
    Write-Host ("Transport type:  {0}" -f $type)
    Write-Host ("xHTTP mode:      {0}" -f $mode)
    Write-Host ("Path:            {0}" -f $path)
    Write-Host ("Identifier:      {0}" -f (Get-Masked $id))
    Write-Host ""
    Write-Host "Generated link:" -ForegroundColor Cyan
    Write-Host $link -ForegroundColor Yellow
    Write-Host ""

    $json = [ordered]@{
        scheme   = $scheme
        id       = $id
        address  = $h
        port     = 443
        security = 'tls'
        sni      = $h
        host     = $h
        fp       = $fp
        type     = $type
        mode     = $mode
        path     = $path
        name     = $name
    } | ConvertTo-Json
    Write-Host "JSON form:" -ForegroundColor Cyan
    Write-Host $json
}

# Resolve the single relay path for templates: prefer the in-memory value, else
# read RELAY_PATH (stored as plain, so its value is readable) from the project.
function Get-CurrentRelayPath {
    if ($script:SelectedProject -and $script:SelectedProject.path) { return $script:SelectedProject.path }
    try {
        foreach ($e in @(Get-EnvVars)) {
            if ($e.key -eq 'RELAY_PATH' -and $e.value) {
                if ($script:SelectedProject) { $script:SelectedProject.path = $e.value }
                return $e.value
            }
        }
    } catch { }
    return ''
}

# Resolve the backend URL for a redeploy: prefer the in-memory value, else read the
# BACKEND_URL env var (readable only when it was stored plain, i.e. a rewrite build).
function Get-CurrentBackendUrl {
    if ($script:SelectedProject -and $script:SelectedProject.backendUrl) { return $script:SelectedProject.backendUrl }
    try {
        foreach ($e in @(Get-EnvVars)) {
            if ($e.key -eq 'BACKEND_URL' -and $e.value) {
                if ($script:SelectedProject) { $script:SelectedProject.backendUrl = $e.value }
                return $e.value
            }
        }
    } catch { }
    return ''
}

# Return the project's VERIFIED custom domains (verified, non-*.vercel.app).
function Get-ProjectCustomDomains {
    if (-not $script:SelectedProject) { return @() }
    try {
        $res = Invoke-VercelApi -Method 'GET' -Path "/v9/projects/$($script:SelectedProject.id)/domains"
        if ($res -and $res.domains) {
            return @($res.domains |
                Where-Object { $_.verified -and ($_.name -notlike '*.vercel.app') } |
                ForEach-Object { $_.name })
        }
    } catch { }
    return @()
}

# Zero-friction client config generated straight from a deployment: the public
# host and path are filled in automatically; the user only supplies the UUID
# (blank => a 'UUID-HERE' placeholder so they can paste it later). All other
# fields are the standard xHTTP defaults (tls / xhttp / mode=auto / fp=chrome).
# If the project has a verified custom domain, the user can pick it as the host.
function New-QuickClientConfig {
    param([string]$PublicHost, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($PublicHost)) { return }
    $h = $PublicHost.Replace('https://', '').Replace('http://', '').TrimEnd('/')
    $p = Format-PathValue $Path '/api'

    Write-Title "Ready-to-use Client Config"
    Write-Info "Host and path are taken from this deployment - you only add the UUID."

    # Offer any verified custom domain as the host (default stays the Vercel host).
    $hostChoices = @($h)
    foreach ($d in (Get-ProjectCustomDomains)) { if ($hostChoices -notcontains $d) { $hostChoices += $d } }
    if ($hostChoices.Count -gt 1) {
        Write-Host ""
        Write-Info "This project has a verified custom domain. Choose the host for this config:"
        for ($i = 0; $i -lt $hostChoices.Count; $i++) {
            $tag = if ($i -eq 0) { ' (Vercel host)' } else { ' (custom domain)' }
            Write-Host ("    [{0}] {1}{2}" -f $i, $hostChoices[$i], $tag) -ForegroundColor Gray
        }
        $hsel = (Read-Host ("  {0} Host choice [0]" -f $script:Ui.ARR)).Trim()
        $hi = 0
        if ([int]::TryParse($hsel, [ref]$hi) -and $hi -ge 0 -and $hi -lt $hostChoices.Count) { $h = $hostChoices[$hi] }
        Write-Info ("Using host: {0}" -f $h)
    }

    Write-Host ""
    $id = Read-Host ("  {0} Client UUID (press Enter to insert a 'UUID-HERE' placeholder)" -f $script:Ui.ARR)
    if ($null -eq $id) { $id = '' }
    $id = $id.Trim()
    $placeholder = [string]::IsNullOrWhiteSpace($id)
    if ($placeholder) { $id = 'UUID-HERE' }

    $scheme = 'vless'; $type = 'xhttp'; $mode = 'auto'; $fp = 'chrome'
    $name = if ($script:SelectedProject) { $script:SelectedProject.name } else { 'relay' }
    $encPath = [uri]::EscapeDataString($p)
    $encName = [uri]::EscapeDataString($name)
    $link = "$($scheme)://$($id)@$($h):443?security=tls&sni=$($h)&fp=$($fp)&host=$($h)&type=$($type)&mode=$($mode)&path=$($encPath)&encryption=none#$($encName)"

    Write-Host ""
    Write-KeyVal 'Address'     $h 'White'
    Write-KeyVal 'SNI / Host'  $h 'White'
    Write-KeyVal 'Port'        '443' 'White'
    Write-KeyVal 'Security'    'tls' 'White'
    Write-KeyVal 'Type'        $type 'White'
    Write-KeyVal 'Mode'        $mode 'White'
    Write-KeyVal 'Fingerprint' $fp 'White'
    Write-KeyVal 'Path'        $p 'White'
    if ($placeholder) { Write-KeyVal 'UUID' 'UUID-HERE (replace before use)' 'Yellow' }
    else              { Write-KeyVal 'UUID' (Get-Masked $id) 'White' }
    Write-Host ""
    Write-Host "  Share link:" -ForegroundColor Cyan
    Write-Host ("  " + $link) -ForegroundColor Yellow
    Write-Host ""

    $json = [ordered]@{
        scheme = $scheme; id = $id; address = $h; port = 443; security = 'tls'
        sni = $h; host = $h; fp = $fp; type = $type; mode = $mode; path = $p; name = $name
    } | ConvertTo-Json
    Write-Host "  JSON form:" -ForegroundColor Cyan
    foreach ($jl in ($json -split "`r?`n")) { Write-Host ("  " + $jl) }
    if ($placeholder) { Write-Tip "Replace UUID-HERE with your client UUID, then import the link." }
}

# ----------------------------------------------------------------------------
# Guided first-run flow (create -> env -> deploy -> domain -> template)
# ----------------------------------------------------------------------------
function Show-FinalSummary {
    if (-not $script:SelectedProject) { return }
    Write-Title "Deployment Summary"
    $lines = @(
        ("Project    {0}" -f $script:SelectedProject.name),
        ("Public URL https://{0}" -f $script:SelectedProject.url)
    )
    if ($script:SelectedProject.path) { $lines += ("Path       {0}  (client = inbound)" -f $script:SelectedProject.path) }
    Write-Box -Color Green -TextColor White -Lines $lines
    Write-Host ""
    # The deploy step already generated a ready-to-use client config. Point the
    # user to [11] if they later want a fully-customized one (e.g. a custom domain).
    Write-Tip "A client config was generated above. Use [11] any time to make a custom one."
}

function Invoke-GuidedDeploy {
    if (-not (Ensure-Login)) { return }
    Write-Title "Create & Deploy New Relay Project"
    Write-Info "All settings are collected first. Nothing is created in your account until"
    Write-Info "you confirm - so quitting now leaves NO empty project behind."

    # --- 1) Collect everything (no API writes yet) ----------------------------
    $name = Read-ProjectName
    if (-not $name) { return }

    $backend = ''
    while (-not (Test-BackendUrl $backend)) {
        $backend = Read-Host "Backend URL (e.g. https://backend.example.com:8443)"
        if (-not (Test-BackendUrl $backend)) { Write-Warn "Enter a valid http(s) URL." }
    }
    $backend = $backend.Trim()

    Write-Info "Path: the single path your client uses AND your 3x-ui/Xray inbound listens on."
    Write-Info "It is forwarded to the backend unchanged - both sides must use this same value."
    Write-Info "Press Enter to accept the shown default; otherwise type your inbound path."
    $path = Format-PathValue (Read-Host "Path (must match your inbound) [/api]") '/api'
    Write-Info ("Using path: {0}" -f $path)

    # Choose the build (Node serverless function vs. function-less edge rewrite).
    $mode = Read-BuildMode

    if ($mode -eq 'node') {
        Write-Info "ALLOW_INSECURE: Y = do NOT verify the backend's TLS certificate (needed for a"
        Write-Info "self-signed cert). N = verify it (use only if the backend has a valid CA cert)."
        $insecure = if (Read-YesNo "Allow insecure backend TLS (self-signed cert)?" $true) { '1' } else { '0' }
        $md      = Get-MaxDurationInteractive
        $regions = @(Select-DeployRegions -BackendUrl $backend)
    } else {
        Write-Warn "Rewrite mode proxies at Vercel's edge and CANNOT skip backend TLS verification."
        Write-Warn "Your backend must serve a valid, publicly-trusted certificate on the URL above."
        $insecure = '0'; $md = 0; $regions = @()
    }

    # --- 2) Review + confirm BEFORE creating anything -------------------------
    Write-Title "Review - nothing created yet"
    if ($mode -eq 'node') {
        $insecureLabel = if ($insecure -eq '1') { 'yes (skip backend TLS verify)' } else { 'no (verify backend TLS)' }
        Write-Box -Color Yellow -TextColor White -Lines @(
            ("Project name    {0}" -f $name),
            ("Build           Node function (api/relay.js)"),
            ("Backend URL     {0}" -f $backend),
            ("Path            {0}" -f $path),
            ("Allow insecure  {0}" -f $insecureLabel),
            ("maxDuration     {0}s" -f $md),
            ("Region(s)       {0}" -f ($regions -join ', '))
        )
    } else {
        Write-Box -Color Yellow -TextColor White -Lines @(
            ("Project name    {0}" -f $name),
            ("Build           Rewrite / edge proxy (vercel.json only, no function)"),
            ("Backend URL     {0}" -f $backend),
            ("Path            {0}" -f $path),
            ("TLS to backend  verified at edge (valid public cert REQUIRED)")
        )
    }
    Write-Host ""
    if (-not (Read-YesNo "Create the project and deploy with these settings?" $true)) {
        Write-Info "Cancelled. No project was created in your account."
        return
    }

    # --- 3) Now create + configure + deploy (uses pre-collected values) -------
    $proj = New-Project -Name $name
    if (-not $proj) { return }

    Write-Info "Setting environment variables..."
    Set-EnvVar -Key 'RELAY_PATH' -Value $path -Type 'plain'   # the single agreed path (visible)
    if ($mode -eq 'node') {
        # Node function reads these at runtime.
        Set-EnvVar -Key 'BACKEND_URL'    -Value $backend
        Set-EnvVar -Key 'ALLOW_INSECURE' -Value $insecure -Type 'plain'
    } else {
        # Rewrite build bakes the backend into vercel.json; store it (visible) so a
        # later redeploy/select can recover it without re-typing.
        Set-EnvVar -Key 'BACKEND_URL' -Value $backend -Type 'plain'
    }

    # Cache backend URL + path so redeploys/templates can reuse them.
    $script:SelectedProject.backendUrl = $backend
    $script:SelectedProject.path       = $path

    Deploy-Relay -BackendUrl $backend -MaxDuration $md -Regions $regions -Mode $mode

    if (Read-YesNo "Add a custom domain now?" $false) { Add-Domain }

    Show-FinalSummary
}

# ----------------------------------------------------------------------------
# Main menu loop
# ----------------------------------------------------------------------------
# One menu row: dim group indent, cyan key, white label.
function Write-MenuItem {
    param([string]$Key, [string]$Label)
    Write-Host ("    {0,-4}" -f ("[$Key]")) -ForegroundColor Cyan -NoNewline
    Write-Host (" $Label") -ForegroundColor White
}
function Write-MenuGroup { param([string]$T) Write-Host ("  $T") -ForegroundColor DarkGray }

function Format-MenuField {
    param([string]$Value, [int]$Width)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt $Width) {
        if ($Width -le 3) { return $Value.Substring(0, $Width) }
        return $Value.Substring(0, $Width - 3) + '...'
    }
    return $Value.PadRight($Width)
}

function Write-MenuStatusRow {
    param(
        [string]$Label1, [string]$Value1, [System.ConsoleColor]$Color1,
        [string]$Label2, [string]$Value2, [System.ConsoleColor]$Color2
    )
    $u = $script:Ui
    Write-Host ('  ' + [string]$u.V + ' ') -ForegroundColor DarkCyan -NoNewline
    Write-Host (Format-MenuField $Label1 11) -ForegroundColor DarkGray -NoNewline
    Write-Host (Format-MenuField $Value1 23) -ForegroundColor $Color1 -NoNewline
    Write-Host (Format-MenuField $Label2 12) -ForegroundColor DarkGray -NoNewline
    Write-Host (Format-MenuField $Value2 25) -ForegroundColor $Color2 -NoNewline
    Write-Host ([string]$u.V) -ForegroundColor DarkCyan
}

function Show-Menu {
    $loggedIn = [bool]$script:Token
    $identity = if ($script:Account -and $script:Account.username) { [string]$script:Account.username }
                elseif ($loggedIn) { '(validating)' } else { 'not logged in' }
    $personalPlan = if ($script:Account) {
        Format-PlanLabel -Plan $script:PersonalPlan -BillingStatus $script:PersonalBillingStatus `
            -Blocked $script:PersonalBlocked
    } else { '-' }
    $scope = if ($script:SelectedScope -and $script:SelectedScope.Kind -eq 'team') {
        "Team $($script:SelectedScope.Slug)"
    } elseif ($script:SelectedScope) { "Personal $($script:SelectedScope.Name)" }
      elseif ($loggedIn) { '(not selected)' } else { '-' }
    $scopePlan = if ($script:SelectedScope) {
        Format-PlanLabel -Plan $script:ScopePlan -BillingStatus $script:ScopeBillingStatus `
            -Blocked $script:ScopeBlocked
    } else { '-' }
    $identityColor = if ($loggedIn) { 'Green' } else { 'Red' }
    $scopeColor = if ($script:SelectedScope) { 'Green' } else { 'Red' }
    $proj  = if ($script:SelectedProject) { $script:SelectedProject.name } else { '(none selected)' }
    $prof  = if ($script:ActiveProfile) { $script:ActiveProfile } else { '-' }

    Write-Host ""
    $u = $script:Ui
    # Three rows clearly separate signed-in identity, personal workspace, and
    # the deployment scope whose plan/limits are applied to every API action.
    Write-Host ('  ' + [string]$u.TL + ([string]$u.H * 72) + [string]$u.TR) -ForegroundColor DarkCyan
    Write-MenuStatusRow 'Identity:' $identity $identityColor 'Personal:' $personalPlan 'White'
    Write-MenuStatusRow 'Deploy:' $scope $scopeColor 'Scope plan:' $scopePlan 'White'
    Write-MenuStatusRow 'Project:' $proj 'Cyan' 'Profile:' $prof 'White'
    Write-Host ('  ' + [string]$u.BL + ([string]$u.H * 72) + [string]$u.BR) -ForegroundColor DarkCyan

    Write-Host ""
    Write-MenuGroup 'IDENTITY & SCOPE'
    Write-MenuItem '1'  'Login with Vercel token'
    Write-MenuItem '2'  'Load / switch saved profile'
    Write-MenuItem '3'  'Identity & scope info'
    Write-MenuItem '4'  'Deployment-scope usage & status'
    Write-MenuItem '15' 'Switch deployment scope'
    Write-Host ""
    Write-MenuGroup 'PROJECT'
    Write-MenuItem '5'  'List projects'
    Write-MenuItem '6'  'New relay project  (guided deploy)'
    Write-MenuItem '7'  'Select / open a project'
    Write-Host ""
    Write-MenuGroup 'CONFIGURE & DEPLOY'
    Write-MenuItem '8'  'Environment variables'
    Write-MenuItem '9'  'Deploy / redeploy relay'
    Write-MenuItem '10' 'Custom domains  (list / add / verify / remove)'
    Write-Host ""
    Write-MenuGroup 'TOOLS'
    Write-MenuItem '11' 'Generate client template'
    Write-MenuItem '12' 'Delete selected project'
    Write-MenuItem '13' 'Delete ALL projects'
    Write-MenuItem '14' 'Delete saved profile'
    Write-MenuItem '0'  'Exit'
    Write-Host ""
    Write-Tip (Get-RandomTip)
}

function Main {
    Clear-Screen
    Show-Banner

    # Friendly first-run behavior: offer to load a saved token, else offer login.
    $saved = @(Get-SavedProfiles)   # also migrates any legacy token.dat to a profile
    if ($saved.Count -gt 0) {
        $label = if ($saved.Count -eq 1) { "A saved token profile ('{0}') was found. Load it now?" -f $saved[0] }
                 else { "{0} saved token profiles were found. Load one now?" -f $saved.Count }
        if (Read-YesNo ("  " + $label) $true) {
            if (Load-SavedToken) { [void](Complete-Login) }
        }
    } else {
        if (Read-YesNo "  No saved token. Login with a Vercel token now?" $true) { Invoke-Login }
    }
    if ($script:Token) { Pause-Menu }   # let the login result be seen before the first clear

    while ($true) {
        Clear-Screen
        Show-Menu
        $choice = (Read-Host "  Select an option").Trim()
        if ($choice -eq '0') {
            Clear-Screen
            Write-Host ""
            Write-Host "  Goodbye." -ForegroundColor Cyan
            return
        }
        Clear-Screen   # run the chosen action on a clean screen
        switch ($choice) {
            '1'  { Invoke-Login }
            '2'  { Switch-Profile }
            '3'  { Show-AccountInfo }
            '4'  { Show-AccountUsage }
            '15' { Switch-DeploymentScope }
            '5'  { [void](Show-Projects) }
            '6'  { Invoke-GuidedDeploy }
            '7'  { Select-Project }
            '8'  { Invoke-EnvMenu }
            '9'  { Deploy-Relay }
            '10' { Invoke-DomainMenu }
            '11' { New-ClientTemplate }
            '12' { Remove-Project }
            '13' { Remove-AllProjects }
            '14' { Remove-SavedToken }
            default { Write-Warn "Unknown option: '$choice'" }
        }
        # Self-paced sub-menus handle their own pacing; leaf screens are held so
        # their output can be read before the next clear.
        if ($choice -notin @('7','8','10')) { Pause-Menu }
    }
}

# Entry point.
try {
    Main
} catch {
    Write-Err ("Fatal error: {0}" -f $_.Exception.Message)
    exit 1
}
