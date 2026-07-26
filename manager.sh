#!/usr/bin/env bash
# ============================================================================
#  manager.sh - Linux/macOS launcher for the XHTTP Relay Deployer.
# ----------------------------------------------------------------------------
#  This runs the EXACT SAME tool as Windows (XHTTPRelayDeploy.ps1) by launching
#  it under PowerShell 7. If `pwsh` is not installed, it auto-installs a
#  user-local copy (no sudo, no system changes) and then runs the tool.
#
#  Usage:
#     bash manager.sh            # run the deployer (installs pwsh if needed)
#     ./manager.sh               # same, if executable
#     bash manager.sh --help     # show this help
#
#  Already have PowerShell 7? If `pwsh` is on your PATH (e.g. installed via
#  `apt install powershell` / `dnf install powershell` / `brew install
#  powershell`), this script uses it and installs nothing.
#
#  Pinned fallback PowerShell version is below; the script normally fetches the
#  latest release tag from GitHub at install time.
# ============================================================================
set -euo pipefail

PS_FALLBACK_VERSION="7.4.6"   # used only if the latest tag can't be fetched

# --- pretty output ----------------------------------------------------------
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'; C_RST=$'\033[0m'
else
    C_OK=''; C_WARN=''; C_ERR=''; C_INFO=''; C_RST=''
fi
info() { printf '%s>%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s\xe2\x9c\x93%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_RST" "$*"; }
die()  { printf '%sx%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 1; }

# --- locate this script + the PowerShell tool next to it --------------------
SOURCE="${BASH_SOURCE[0]:-$0}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [ "${SOURCE#/}" = "$SOURCE" ] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
PS1_FILE="$SCRIPT_DIR/XHTTPRelayDeploy.ps1"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,20p' "$SOURCE" | sed 's/^# \{0,1\}//'
    exit 0
fi

[ -f "$PS1_FILE" ] || die "Cannot find XHTTPRelayDeploy.ps1 next to this script ($SCRIPT_DIR)."

# --- user-local install location for an auto-installed PowerShell -----------
PS_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/powershell"
LOCAL_BIN="$HOME/.local/bin"

# --- find an existing pwsh (PATH first, then a prior user-local install) ----
find_pwsh() {
    if command -v pwsh >/dev/null 2>&1; then command -v pwsh; return 0; fi
    if [ -x "$PS_BASE/pwsh" ]; then printf '%s\n' "$PS_BASE/pwsh"; return 0; fi
    return 1
}

# --- download helper (curl or wget) ----------------------------------------
fetch() { # $1=url  $2=output-file
    if command -v curl >/dev/null 2>&1; then
        curl -fSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        die "Need 'curl' or 'wget' to download PowerShell. Please install one and re-run."
    fi
}
fetch_stdout() { # $1=url  (prints body; empty on failure)
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then wget -qO- "$1" 2>/dev/null || true
    fi
}

# --- install a user-local PowerShell 7 (no sudo) ---------------------------
install_pwsh() {
    command -v tar >/dev/null 2>&1 || die "Need 'tar' to unpack PowerShell. Please install it and re-run."

    # CPU architecture.
    local uname_m; uname_m="$(uname -m)"
    local arch
    case "$uname_m" in
        x86_64|amd64)   arch="x64" ;;
        aarch64|arm64)  arch="arm64" ;;
        *) die "Unsupported CPU architecture '$uname_m'. Install PowerShell 7 manually (see README) and re-run." ;;
    esac

    # libc flavor: Alpine and other musl systems need the -musl- build.
    local suffix="$arch"
    if [ -f /etc/alpine-release ] || (ldd --version 2>&1 | grep -qi musl); then
        suffix="musl-$arch"
    fi

    # Latest release tag, with a pinned fallback. The '|| true' keeps a failed
    # fetch/grep (e.g. offline or rate-limited) from aborting under 'set -e'.
    local tag ver
    tag="$( { fetch_stdout https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
           | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1; } || true )"
    ver="${tag#v}"
    [ -n "$ver" ] || ver="$PS_FALLBACK_VERSION"

    local file="powershell-${ver}-linux-${suffix}.tar.gz"
    local url="https://github.com/PowerShell/PowerShell/releases/download/v${ver}/${file}"

    info "Installing PowerShell ${ver} (linux-${suffix}) into: $PS_BASE"
    info "Source: $url"
    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    fetch "$url" "$tmp/$file" || die "Download failed: $url"
    mkdir -p "$PS_BASE"
    tar -xzf "$tmp/$file" -C "$PS_BASE" || die "Failed to extract $file"
    chmod +x "$PS_BASE/pwsh" 2>/dev/null || true
    [ -x "$PS_BASE/pwsh" ] || die "PowerShell did not unpack as expected (no $PS_BASE/pwsh)."

    # Convenience symlink so `pwsh` is callable later if ~/.local/bin is on PATH.
    mkdir -p "$LOCAL_BIN"
    ln -sf "$PS_BASE/pwsh" "$LOCAL_BIN/pwsh" 2>/dev/null || true

    ok "PowerShell ${ver} installed."
    case ":$PATH:" in
        *":$LOCAL_BIN:"*) : ;;
        *) info "Tip: add '$LOCAL_BIN' to your PATH to run 'pwsh' directly later." ;;
    esac
}

# --- main -------------------------------------------------------------------
PWSH=""
if PWSH="$(find_pwsh)"; then
    :
else
    warn "PowerShell 7 (pwsh) was not found - installing a user-local copy (no sudo)."
    install_pwsh
    PWSH="$(find_pwsh)" || die "PowerShell install completed but 'pwsh' still not found."
fi

info "Launching the deployer with: $PWSH"
# If pwsh fails to start due to missing system libraries (libicu / openssl on a
# minimal distro), install those packages or use your distro's PowerShell package
# (see README). Otherwise this runs the identical menu-driven tool as on Windows.
exec "$PWSH" -NoProfile -File "$PS1_FILE" "$@"
