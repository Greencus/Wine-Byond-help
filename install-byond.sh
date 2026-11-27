#!/usr/bin/env bash
# =============================================================================
# install-byond.sh - standalone BYOND-on-Wine installer
#
# Replicates the Lutris "Wine-Byond-help" x64byond.yaml steps, but launches the
# game DIRECTLY with wine (never through Lutris' lutris-wrapper, which sets
# PR_SET_CHILD_SUBREAPER and hangs WebView2/Chromium on "Loading game
# information...").
#
# It leaves behind:
#   /etc/byond/byond-launch.conf        (wine version, overrides, env - editable)
#   /usr/local/bin/byond-launcher       (conf-driven launcher script)
#   /usr/share/applications/byond.desktop
#   <prefix>/space-handler.sh           (byond:// URL handler, launches via launcher)
#
# All network sources are overridable variables so you can point them at your
# own repo after you create it (see CUSTOM REPO VARIABLES below).
#
# Usage:
#   ./install-byond.sh [options]
#   sudo ./install-byond.sh --system        # install launcher/desktop system-wide
#
# Options:
#   --prefix DIR            Wine prefix (default: $HOME/Games/byond)
#   --wine PATH             wine binary  (default: /usr/bin/wine, must be >=10.8)
#   --byond-version VER     BYOND build  (default: 516.1667)
#   --no-dxvk               Do not install DXVK / do not set DXVK overrides
#   --renderer-limit N      WebView2 renderer process limit (default: 4)
#   --no-font-patch         Skip merging hieroglyph/emoji/runic/math glyphs
#   --math-font PATH        Math glyph source (Symbola.ttf recommended)
#   --symbola-url URL         Symbola zip URL (fontlibrary.org by default)
#   --repo-base URL         Base URL of your custom repo (raw github style)
#   --user                  Install launcher/desktop under ~/.local (no sudo)
#   --system                Install launcher/desktop system-wide (uses sudo)
#   --yes                   Assume yes; do not prompt before system install
#   --dry-run               Only generate conf/launcher/desktop into cache and print them
#   --launcher-only         Skip prefix setup; only install conf/launcher/desktop
#                           (use this on an already-configured prefix)
#   -h, --help              Show this help
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# CUSTOM REPO VARIABLES
#   After you create your own repo, either export these before running, or
#   pass --repo-base, or edit the defaults here. Any missing asset that lives
#   in your repo can be given its own full URL variable (see below).
# ---------------------------------------------------------------------------
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/kinggoldcatter/Wine-Byond-help/master}"
SMOFONT_URL="${SMOFONT_URL:-${REPO_BASE}/extra/fonts/smalle.zip}"
NTID_URL="${NTID_URL:-${REPO_BASE}/extra/NT-ID.sh}"
SPACE_HANDLER_URL="${SPACE_HANDLER_URL:-${REPO_BASE}/extra/space-handler.sh}"
FONT_PATCH_SCRIPT_URL="${FONT_PATCH_SCRIPT_URL:-${REPO_BASE}/extra/byond-font-patch.py}"
# Glyph-source fonts for the WebView2 font patch (see byond-font-patch.py).
EGYPT_URL="${EGYPT_URL:-https://raw.githubusercontent.com/google/fonts/main/ofl/notosansegyptianhieroglyphs/NotoSansEgyptianHieroglyphs-Regular.ttf}"
RUNIC_URL="${RUNIC_URL:-https://raw.githubusercontent.com/google/fonts/main/ofl/notosansrunic/NotoSansRunic-Regular.ttf}"
EMOJI_URL="${EMOJI_URL:-https://raw.githubusercontent.com/google/fonts/main/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf}"
SYMBOLA_URL="${SYMBOLA_URL:-https://fontlibrary.org/api/catalogue/symbola/download}"
MATH_FONT="${MATH_FONT:-}"          # optional path to Symbola.ttf (preferred math source)
FONT_PATCH="${FONT_PATCH:-1}"       # 1 = merge hieroglyph/emoji/runic/math glyphs
# Shared helper scripts are downloaded from REPO_BASE.

# ---------------------------------------------------------------------------
# Upstream / toolchain variables
# ---------------------------------------------------------------------------
WINE_BIN="${WINE_BIN:-/usr/bin/wine}"
PREFIX="${PREFIX:-$HOME/Games/byond}"
BYOND_VERSION="${BYOND_VERSION:-516.1667}"
BYOND_URL="${BYOND_URL:-https://www.byond.com/download/build/516/${BYOND_VERSION}_byond.exe}"
WEBVIEW2_URL="${WEBVIEW2_URL:-https://go.microsoft.com/fwlink/?linkid=2124701}"
DXVK_ENABLED="${DXVK_ENABLED:-1}"
DXVK_VERSION="${DXVK_VERSION:-2.6.2}"
DXVK_URL="${DXVK_URL:-https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VERSION}/dxvk-${DXVK_VERSION}.tar.gz}"
WEBVIEW2_RENDERER_LIMIT="${WEBVIEW2_RENDERER_LIMIT:-4}"

SYSTEM_INSTALL="${SYSTEM_INSTALL:-1}"   # 1 => /usr/local,/usr/share,/etc ; 0 => ~/.local,~/.config
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
LAUNCHER_ONLY="${LAUNCHER_ONLY:-0}"
CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/byond-installer}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
c_blue=$'\033[1;34m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '%s[byond]%s %s\n' "$c_blue" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n'  "$c_yel"  "$c_off" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$c_red"  "$c_off" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

usage() { awk 'NR<=2{next} /^# ={10,}$/{exit} {sub(/^# ?/,""); print}' "$0"; exit 0; }

first_file() { for f in "$@"; do [ -n "$f" ] && [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; done; return 1; }

wine_run() {
  WINEPREFIX="$PREFIX" WINEARCH=win64 WINEDEBUG="${WINEDEBUG:--all}" \
    "$WINE_BIN" "$@"
}

download() { # download <url> <dest-file>
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then log "using cached $(basename "$dest")"; return 0; fi
  log "downloading $(basename "$dest")"
  curl -fL --retry 3 --connect-timeout 20 --max-time 900 -o "$dest.part" "$url" \
    || { rm -f "$dest.part"; die "download failed: $url"; }
  mv -f "$dest.part" "$dest"
}

have_passwordless_sudo() { sudo -n true >/dev/null 2>&1; }

confirm() { # confirm <prompt>
  [ "$ASSUME_YES" = "1" ] && return 0
  local ans
  read -r -p "$1 [y/N] " ans || true
  [[ "$ans" =~ ^[Yy] ]]
}

place() { # place <src> <dest-abs> <mode> <0|1 use_sudo>
  local src="$1" dest="$2" mode="$3" use_sudo="${4:-0}"
  if [ "$use_sudo" = "1" ]; then
    sudo install -Dm"$mode" "$src" "$dest"
  else
    mkdir -p "$(dirname "$dest")"
    install -m"$mode" "$src" "$dest"
  fi
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)            usage ;;
    --prefix)             PREFIX="$2"; shift 2 ;;
    --wine)               WINE_BIN="$2"; shift 2 ;;
    --byond-version)      BYOND_VERSION="$2"; shift 2 ;;
    --byond-url)          BYOND_URL="$2"; shift 2 ;;
    --no-dxvk)            DXVK_ENABLED=0; shift ;;
    --no-font-patch)      FONT_PATCH=0; shift ;;
    --math-font)          MATH_FONT="$2"; shift 2 ;;
    --symbola-url)          SYMBOLA_URL="$2"; shift 2 ;;
    --renderer-limit)     WEBVIEW2_RENDERER_LIMIT="$2"; shift 2 ;;
    --repo-base)          REPO_BASE="$2"; shift 2
                          SMOFONT_URL="${REPO_BASE}/extra/fonts/smalle.zip"
                          NTID_URL="${REPO_BASE}/extra/NT-ID.sh"
                          SPACE_HANDLER_URL="${REPO_BASE}/extra/space-handler.sh"
                          FONT_PATCH_SCRIPT_URL="${REPO_BASE}/extra/byond-font-patch.py" ;;
    --user)               SYSTEM_INSTALL=0; shift ;;
    --system)             SYSTEM_INSTALL=1; shift ;;
    --yes)                ASSUME_YES=1; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --launcher-only)      LAUNCHER_ONLY=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

export PREFIX WINE_BIN
PREFIX="${PREFIX%/}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
log "BYOND standalone installer"
log "  wine        : $WINE_BIN"
log "  prefix      : $PREFIX"
log "  BYOND       : $BYOND_VERSION"
log "  DXVK        : $DXVK_ENABLED (v$DXVK_VERSION)"
log "  repo base   : $REPO_BASE"

need "$WINE_BIN"
need winetricks; need curl; need unzip; need tar; need sha256sum
mkdir -p "$CACHE_DIR"

"$WINE_BIN" --version >/dev/null 2>&1 || die "wine binary not runnable: $WINE_BIN"
wine_ver="$("$WINE_BIN" --version 2>/dev/null | sed -E 's/^wine-//' | head -n1)"
log "detected wine: $wine_ver (need >= 10.8, 11.x recommended)"

# ---------------------------------------------------------------------------
# Artifact generation (config + launcher + desktop entry)
# ---------------------------------------------------------------------------
if [ "$DXVK_ENABLED" = "1" ]; then
  dll_overrides='d3d10core,d3d11,d3d12,dxgi=n'
else
  dll_overrides=''
fi

gen_artifacts() { # gen_artifacts <outdir>
  local out="$1"
  mkdir -p "$out"

  cat > "$out/byond-launch.conf" <<EOF
# byond-launch.conf - read by byond-launcher
# Edit freely; a same-named file in ~/.config/byond/ overrides this one.

# Wine build to use for the game (system wine >= 10.8, 11.x recommended).
WINE_BIN="$WINE_BIN"

# Wine prefix created by install-byond.sh.
WINEPREFIX="$PREFIX"

# The BYOND executable, as a Windows path.
GAME_EXE='C:\\Program Files (x86)\\BYOND\\bin\\byond.exe'

# DLL overrides (DXVK). Leave empty to use Wine's built-in wined3d.
WINEDLLOVERRIDES="$dll_overrides"

# Environment (matches a fast, well-behaved configuration).
WINEDEBUG="-all"
DXVK_LOG_LEVEL="error"
WINEESYNC="1"
WINEFSYNC="1"
WINE_LARGE_ADDRESS_AWARE="1"

# Extra arguments appended to the wine command.
GAME_ARGS=""

# NOTE: do not launch this through a child-subreaper (e.g. Lutris'
# lutris-wrapper). Chromium/WebView2 hangs when wine is a subreaper.
EOF

  cat > "$out/byond-launcher" <<'LAUNCHER'
#!/usr/bin/env bash
# byond-launcher - conf-driven BYOND launcher (no Lutris wrapper, no subreaper).
set -euo pipefail

SYSTEM_CONF="${BYOND_CONF:-/etc/byond/byond-launch.conf}"
USER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/byond/byond-launch.conf"

conf_found=0
# shellcheck disable=SC1090
if [ -r "$SYSTEM_CONF" ]; then . "$SYSTEM_CONF"; conf_found=1; fi
# shellcheck disable=SC1090
if [ -r "$USER_CONF" ]; then . "$USER_CONF"; conf_found=1; fi
[ "$conf_found" = 1 ] || {
  echo "byond-launcher: no config found ($SYSTEM_CONF or $USER_CONF)" >&2
  echo "run install-byond.sh first" >&2
  exit 1
}

: "${WINE_BIN:=/usr/bin/wine}"
: "${WINEPREFIX:?set WINEPREFIX in $SYSTEM_CONF}"
: "${GAME_EXE:?set GAME_EXE in $SYSTEM_CONF}"

export WINEPREFIX
[ -n "${WINEARCH:-}" ]            && export WINEARCH
[ -n "${WINEDLLOVERRIDES:-}" ]    && export WINEDLLOVERRIDES
[ -n "${WINEDEBUG:-}" ]           && export WINEDEBUG
[ -n "${DXVK_LOG_LEVEL:-}" ]      && export DXVK_LOG_LEVEL
[ -n "${WINEESYNC:-}" ]           && export WINEESYNC
[ -n "${WINEFSYNC:-}" ]           && export WINEFSYNC
[ -n "${WINE_LARGE_ADDRESS_AWARE:-}" ] && export WINE_LARGE_ADDRESS_AWARE

# Serve byond:// URLs through the prefix handler (single menu entry does both).
if [ $# -ge 1 ] && [[ "$1" == *"://"* ]]; then
  handler="$WINEPREFIX/space-handler.sh"
  [ -x "$handler" ] || { echo "byond-launcher: missing $handler" >&2; exit 1; }
  export BYOND_LAUNCHER="${BYOND_LAUNCHER:-$0}"
  exec "$handler" "$1"
fi

# Keep the menu free of Wine's per-prefix shortcut spam. wofi ignores
# NoDisplay, so wine-protocol-*/wine-extension-* entries appear as duplicates.
# Cleaned before and after the game (winemenubuilder regenerates them on start).
cleanup_menu() {
  local apps f
  apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  [ -d "$apps" ] || return 0
  for f in "$apps"/wine-*.desktop; do
    [ -e "$f" ] || continue
    grep -qF "WINEPREFIX=$WINEPREFIX" "$f" 2>/dev/null && rm -f "$f"
  done
  rm -f "$apps/byond-url-handler.desktop"
  return 0
}

args=()
if [ -n "${GAME_ARGS:-}" ]; then read -r -a args <<< "$GAME_ARGS"; fi
# Support: byond-launcher -url "byond://..."
if [ "${1:-}" = "-url" ] && [ -n "${2:-}" ]; then args+=(-url "$2"); fi

cleanup_menu
"$WINE_BIN" "$GAME_EXE" "${args[@]}" &
game_pid=$!
trap 'kill -TERM "$game_pid" 2>/dev/null' INT TERM
rc=0
wait "$game_pid" || rc=$?
trap - INT TERM
cleanup_menu
exit "$rc"
LAUNCHER

  cat > "$out/byond.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=BYOND
Comment=BYOND client (Wine)
Exec=/usr/local/bin/byond-launcher %u
Icon=applications-games
Terminal=false
Categories=Game;
MimeType=x-scheme-handler/byond;
StartupNotify=true
EOF

  chmod 755 "$out/byond-launcher"
}

if [ "$DRY_RUN" = "1" ]; then
  gen_artifacts "$CACHE_DIR/dryrun"
  log "dry run: artifacts staged in $CACHE_DIR/dryrun (nothing installed)"
  for f in byond-launch.conf byond-launcher byond.desktop; do
    echo "----- $f -----"
    sed 's/^/  /' "$CACHE_DIR/dryrun/$f"
  done
  exit 0
fi

if [ "$LAUNCHER_ONLY" != "1" ]; then
# ---------------------------------------------------------------------------
# 1. Create / update the win64 prefix
# ---------------------------------------------------------------------------
log "creating/updating win64 prefix"
export WINEPREFIX="$PREFIX" WINEARCH=win64
mkdir -p "$(dirname "$PREFIX")"
"$WINE_BIN" wineboot -u >/dev/null 2>&1 || warn "wineboot returned non-zero (often harmless)"
[ -d "$PREFIX/drive_c" ] || die "prefix was not created at $PREFIX"

# ---------------------------------------------------------------------------
# 2. winetricks verbs (same set as the Lutris YAML)
# ---------------------------------------------------------------------------
if [ ! -f "$PREFIX/winetricks.log" ] || ! grep -qx 'msftedit' "$PREFIX/winetricks.log" 2>/dev/null; then
  log "installing winetricks verbs (vcrun2022 dxtrans corefonts riched20 msftedit)"
  WINE="$WINE_BIN" WINEPREFIX="$PREFIX" WINEARCH=win64 WINEDEBUG=-all \
    winetricks -q vcrun2022 dxtrans corefonts riched20 msftedit \
    || warn "winetricks reported errors - check output if things misbehave"
else
  log "winetricks verbs already present"
fi

# ---------------------------------------------------------------------------
# 3. Small fonts
# ---------------------------------------------------------------------------
log "installing Small Fonts"
download "$SMOFONT_URL" "$CACHE_DIR/smalle.zip"
unzip -oq "$CACHE_DIR/smalle.zip" -d "$PREFIX/drive_c/windows/Fonts/"
wine_run reg add \
  'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' \
  /v 'Small Fonts (VGA res)' /t REG_SZ /d 'C:\Windows\Fonts\smalle.fon' /f >/dev/null

# ---------------------------------------------------------------------------
# 5. Stable C: volume serial (BYOND identity)
# ---------------------------------------------------------------------------
log "configuring stable C: serial (NT-ID)"
download "$NTID_URL" "$CACHE_DIR/NT-ID.sh"
bash "$CACHE_DIR/NT-ID.sh" "$PREFIX" || warn "NT-ID step failed"

# ---------------------------------------------------------------------------
# 6. WebView2 (x64 Evergreen runtime)
# ---------------------------------------------------------------------------
log "installing WebView2 runtime (this can take a few minutes)"
download "$WEBVIEW2_URL" "$CACHE_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
wine_run "$CACHE_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64.exe" /silent /install >/dev/null 2>&1 \
  || warn "WebView2 installer returned non-zero (often harmless)"
wine_run taskkill /f /im MicrosoftEdgeUpdate.exe >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 7. Registry work-arounds (from the YAML / project notes)
# ---------------------------------------------------------------------------
log "applying registry work-arounds"
wine_run reg add 'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe' \
  /v version /t REG_SZ /d win7 /f >/dev/null

WEBVIEW_ARGS="--ignore-gpu-blocklist --use-gl=angle --use-angle=d3d11 --disable-direct-composition --renderer-process-limit=${WEBVIEW2_RENDERER_LIMIT} --process-per-site --disable-site-isolation-trials"
wine_run reg add 'HKLM\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments' \
  /v '*' /t REG_SZ /d "$WEBVIEW_ARGS" /f >/dev/null

# ---------------------------------------------------------------------------
# 8. BYOND itself (silent). It exits 50944 on success; treat that as OK.
# ---------------------------------------------------------------------------
log "installing BYOND $BYOND_VERSION"
download "$BYOND_URL" "$CACHE_DIR/$(basename "$BYOND_URL")"
set +e
wine_run "$CACHE_DIR/$(basename "$BYOND_URL")" /S >/dev/null 2>&1
byond_rc=$?
set -e
[ "$byond_rc" = "0" ] || [ "$byond_rc" = "50944" ] || warn "BYOND installer exit code $byond_rc (expected 0/50944)"
[ -f "$PREFIX/drive_c/Program Files (x86)/BYOND/bin/byond.exe" ] \
  || die "byond.exe not found after install"

# ---------------------------------------------------------------------------
# 9. DXVK (optional)
# ---------------------------------------------------------------------------
if [ "$DXVK_ENABLED" = "1" ]; then
  log "installing DXVK v$DXVK_VERSION"
  download "$DXVK_URL" "$CACHE_DIR/dxvk.tar.gz"
  rm -rf "$CACHE_DIR/dxvk"; mkdir -p "$CACHE_DIR/dxvk"
  tar -xzf "$CACHE_DIR/dxvk.tar.gz" -C "$CACHE_DIR/dxvk"
  dxvk_root="$(find "$CACHE_DIR/dxvk" -maxdepth 1 -type d -name 'dxvk-*' | head -n1)"
  [ -n "$dxvk_root" ] || die "could not locate extracted DXVK"
  # --remove-destination: replace any existing (possibly symlinked, e.g. into
  # a Lutris runtime dir) DLL instead of writing through the symlink.
  cp -f --remove-destination "$dxvk_root/x64/"*.dll "$PREFIX/drive_c/windows/system32/"
  cp -f --remove-destination "$dxvk_root/x32/"*.dll "$PREFIX/drive_c/windows/syswow64/"
fi

# ---------------------------------------------------------------------------
# 10. BYOND-packaged DirectX
# ---------------------------------------------------------------------------
dxsetup="$PREFIX/drive_c/Program Files (x86)/BYOND/directx/DXSETUP.exe"
if [ -f "$dxsetup" ]; then
  log "installing BYOND-packaged DirectX"
  wine_run "$dxsetup" /silent >/dev/null 2>&1 || warn "DXSETUP returned non-zero"
fi

else
  log "--launcher-only: skipping wine/prefix/BYOND setup"
fi

# ---------------------------------------------------------------------------
# 3b. Prepare glyph source fonts and invoke the shared font-patch script.
#     The helper handles merging, backups, symlinks, and verification.
# ---------------------------------------------------------------------------
if [ "$FONT_PATCH" = "1" ]; then
  if pgrep -x byond.exe >/dev/null 2>&1; then
    warn "BYOND is running - skipping font patch (close it and rerun to apply)"
  elif ! python3 -c 'import fontTools' >/dev/null 2>&1; then
    warn "python fontTools missing - skipping font patch"
    warn "install it (Arch: sudo pacman -S python-fonttools) and rerun"
  else
    log "patching WebView2 core fonts with hieroglyph/emoji/runic/math glyphs"
    download "$FONT_PATCH_SCRIPT_URL" "$CACHE_DIR/byond-font-patch.py"
    FONTS_CACHE="$CACHE_DIR/fonts"; mkdir -p "$FONTS_CACHE"

    egypt_font="$(first_file "$FONTS_CACHE/NotoSansEgyptianHieroglyphs-Regular.ttf" \
      /usr/share/fonts/noto/NotoSansEgyptianHieroglyphs-Regular.ttf \
      /usr/share/fonts/TTF/NotoSansEgyptianHieroglyphs-Regular.ttf || true)"
    if [ -z "$egypt_font" ]; then
      download "$EGYPT_URL" "$FONTS_CACHE/NotoSansEgyptianHieroglyphs-Regular.ttf"
      egypt_font="$FONTS_CACHE/NotoSansEgyptianHieroglyphs-Regular.ttf"
    fi

    runic_font="$(first_file "$FONTS_CACHE/NotoSansRunic-Regular.ttf" \
      /usr/share/fonts/noto/NotoSansRunic-Regular.ttf \
      /usr/share/fonts/TTF/NotoSansRunic-Regular.ttf || true)"
    if [ -z "$runic_font" ]; then
      download "$RUNIC_URL" "$FONTS_CACHE/NotoSansRunic-Regular.ttf"
      runic_font="$FONTS_CACHE/NotoSansRunic-Regular.ttf"
    fi

    emoji_font="$(first_file "$FONTS_CACHE/NotoEmoji-Regular.ttf" || true)"
    if [ -z "$emoji_font" ]; then
      download "$EMOJI_URL" "$FONTS_CACHE/NotoEmoji-Regular.ttf"
      emoji_font="$FONTS_CACHE/NotoEmoji-Regular.ttf"
    fi

    font_args=(--prefix "$PREFIX" --egypt "$egypt_font" --runic "$runic_font" \
               --emoji "$emoji_font" --verify)
    symbola_font=""
    if [ -n "$MATH_FONT" ] && [ -f "$MATH_FONT" ]; then
      symbola_font="$MATH_FONT"
    else
      symbola="$(first_file /usr/share/fonts/TTF/Symbola.ttf \
        /usr/share/fonts/truetype/symbola/Symbola.ttf || true)"
      if [ -n "$symbola" ]; then
        symbola_font="$symbola"
      else
        log "downloading Symbola from fontlibrary.org"
        download "$SYMBOLA_URL" "$FONTS_CACHE/symbola.zip"
        unzip -oq "$FONTS_CACHE/symbola.zip" Symbola_hint.ttf -d "$FONTS_CACHE/"
        symbola_font="$FONTS_CACHE/Symbola_hint.ttf"
        [ -f "$symbola_font" ] || symbola_font="$FONTS_CACHE/Symbola.ttf"
      fi
    fi
    [ -n "$symbola_font" ] && font_args+=(--math "$symbola_font")
    python3 "$CACHE_DIR/byond-font-patch.py" "${font_args[@]}" \
      || warn "font patch failed - BYOND will run but some Unicode may show as boxes"
  fi
fi

# ---------------------------------------------------------------------------
# 4. byond:// URL handler (shared helper)
# ---------------------------------------------------------------------------
log "installing byond:// URL handler"
download "$SPACE_HANDLER_URL" "$CACHE_DIR/space-handler.sh"
place "$CACHE_DIR/space-handler.sh" "$PREFIX/space-handler.sh" 755 0
bash "$PREFIX/space-handler.sh" --register || warn "URL handler registration failed (XDG?)"

# ---------------------------------------------------------------------------
# 11-13. Generate config, launcher and desktop entry
# ---------------------------------------------------------------------------
gen_artifacts "$CACHE_DIR/artifacts"
CONF_TMP="$CACHE_DIR/artifacts/byond-launch.conf"
LAUNCHER_TMP="$CACHE_DIR/artifacts/byond-launcher"
DESKTOP_TMP="$CACHE_DIR/artifacts/byond.desktop"

# ---------------------------------------------------------------------------
# 14. Install config + launcher + desktop entry
# ---------------------------------------------------------------------------
if [ "$SYSTEM_INSTALL" = "1" ]; then
  CONF_DEST="/etc/byond/byond-launch.conf"
  LAUNCH_DEST="/usr/local/bin/byond-launcher"
  DESKTOP_DEST="/usr/share/applications/byond.desktop"
  use_sudo=1
  if ! sudo -n true >/dev/null 2>&1; then
    confirm "Install launcher/desktop to /usr/local and /usr/share (needs sudo)?" \
      || { warn "aborted system install; falling back to ~/.local"; SYSTEM_INSTALL=0; }
  fi
fi

if [ "$SYSTEM_INSTALL" = "1" ]; then
  log "installing system-wide (sudo may prompt)"
  place "$CONF_TMP"   "$CONF_DEST"    644 1
  place "$LAUNCHER_TMP" "$LAUNCH_DEST" 755 1
  place "$DESKTOP_TMP" "$DESKTOP_DEST" 644 1
  sudo update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
else
  CONF_DEST="${XDG_CONFIG_HOME:-$HOME/.config}/byond/byond-launch.conf"
  LAUNCH_DEST="${BIN_DIR:-$HOME/.local/bin}/byond-launcher"
  DESKTOP_DEST="${XDG_DATA_HOME:-$HOME/.local/share}/applications/byond.desktop"
  log "installing per-user"
  place "$CONF_TMP"   "$CONF_DEST"    644 0
  place "$LAUNCHER_TMP" "$LAUNCH_DEST" 755 0
  place "$DESKTOP_TMP" "$DESKTOP_DEST" 644 0
  # Desktop file points at /usr/local/bin; fix it for user install.
  sed -i "s#^Exec=.*#Exec=$LAUNCH_DEST %u#" "$DESKTOP_DEST"
  update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" >/dev/null 2>&1 || true
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "add ~/.local/bin to PATH to use byond-launcher";; esac
fi


# ---------------------------------------------------------------------------
# 15. One menu entry only: drop Wine's per-prefix shortcuts and register the
#     single BYOND entry as the byond:// handler.
# ---------------------------------------------------------------------------
apps_user="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
if [ -d "$apps_user" ]; then
  for f in "$apps_user"/wine-*.desktop; do
    [ -e "$f" ] || continue
    grep -qF "WINEPREFIX=$PREFIX" "$f" 2>/dev/null && rm -f "$f"
  done
  rm -f "$apps_user/byond-url-handler.desktop"
fi
if command -v xdg-mime >/dev/null 2>&1; then
  mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
  xdg-mime default byond.desktop x-scheme-handler/byond 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Done."
log "  config   : $CONF_DEST"
log "  launcher : $LAUNCH_DEST"
log "  desktop  : $DESKTOP_DEST"
log "Run 'byond-launcher' or launch BYOND from your application menu."
log "Tweak wine/overrides in the config; a ~/.config/byond/ copy overrides it."
