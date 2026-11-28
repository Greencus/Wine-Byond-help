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
#   --fresh                 Start from a new prefix; back up old prefix and clear cache
#   --remove                Remove the prefix, its backups, cache, and BYOND launcher files
#   --wine PATH             wine binary  (default: /usr/bin/wine, must be >=10.8)
#   --byond-version VER     BYOND build  (default: 516.1667)
#   --byond-url URL         BYOND installer URL (defaults to the selected build)
#   --no-dxvk               Do not install DXVK / do not set DXVK overrides
#   --no-vkd3d              Do not install VKD3D when DXVK is enabled
#   --vkd3d-version VER     VKD3D release (default: 2.14)
#   --no-d3d-extras         Do not install D3D Extras (enabled by default)
#   --d3d-extras-version VER D3D Extras release (default: v2)
#   --renderer-limit N      WebView2 renderer process limit (default: 4)
#   --no-font-patch         Skip merging hieroglyph/emoji/runic/math glyphs
#   --no-watchdog           Disable Space Watchdog
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
# Used only when enabled; override while the watchdog asset is not upstream.
SPACE_WATCHDOG_URL="${SPACE_WATCHDOG_URL:-${REPO_BASE}/extra/space-watchdog.sh}"
# Glyph-source fonts for the WebView2 font patch (see byond-font-patch.py).
EGYPT_URL="${EGYPT_URL:-https://raw.githubusercontent.com/google/fonts/main/ofl/notosansegyptianhieroglyphs/NotoSansEgyptianHieroglyphs-Regular.ttf}"
RUNIC_URL="${RUNIC_URL:-https://raw.githubusercontent.com/google/fonts/main/ofl/notosansrunic/NotoSansRunic-Regular.ttf}"
EMOJI_URL="${EMOJI_URL:-https://raw.githubusercontent.com/google/fonts/main/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf}"
SYMBOLA_URL="${SYMBOLA_URL:-https://fontlibrary.org/api/catalogue/symbola/download}"
MATH_FONT="${MATH_FONT:-}"          # optional path to Symbola.ttf (preferred math source)
FONT_PATCH="${FONT_PATCH:-1}"       # 1 = merge hieroglyph/emoji/runic/math glyphs
# Keep the watchdog off until its script is merged upstream; then change this default to 1.
SPACE_WATCHDOG_ENABLED="${SPACE_WATCHDOG_ENABLED:-0}"
# Shared helper scripts are downloaded from REPO_BASE.

# ---------------------------------------------------------------------------
# Upstream / toolchain variables
# ---------------------------------------------------------------------------
WINE_BIN="${WINE_BIN:-/usr/bin/wine}"
PREFIX="${PREFIX:-$HOME/Games/byond}"
BYOND_VERSION="${BYOND_VERSION:-516.1667}"
BYOND_URL_CUSTOM=0
if [ -n "${BYOND_URL:-}" ]; then
  BYOND_URL_CUSTOM=1
fi
BYOND_URL="${BYOND_URL:-}"
WEBVIEW2_URL="${WEBVIEW2_URL:-https://go.microsoft.com/fwlink/?linkid=2124701}"
DXVK_ENABLED="${DXVK_ENABLED:-1}"
DXVK_VERSION="${DXVK_VERSION:-2.6.2}"
DXVK_URL="${DXVK_URL:-https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VERSION}/dxvk-${DXVK_VERSION}.tar.gz}"
VKD3D_ENABLED="${VKD3D_ENABLED:-auto}"
VKD3D_VERSION="${VKD3D_VERSION:-2.14}"
VKD3D_URL="${VKD3D_URL:-https://github.com/lutris/vkd3d/releases/download/v${VKD3D_VERSION}/vkd3d-${VKD3D_VERSION}.tar.xz}"
D3D_EXTRAS_ENABLED="${D3D_EXTRAS_ENABLED:-1}"
D3D_EXTRAS_VERSION="${D3D_EXTRAS_VERSION:-v2}"
D3D_EXTRAS_URL="${D3D_EXTRAS_URL:-https://github.com/lutris/d3d_extras/releases/download/${D3D_EXTRAS_VERSION}/${D3D_EXTRAS_VERSION}.tar.xz}"
WEBVIEW2_RENDERER_LIMIT="${WEBVIEW2_RENDERER_LIMIT:-4}"

SYSTEM_INSTALL="${SYSTEM_INSTALL:-1}"   # 1 => /usr/local,/usr/share,/etc ; 0 => ~/.local,~/.config
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
LAUNCHER_ONLY="${LAUNCHER_ONLY:-0}"
FRESH_INSTALL="${FRESH_INSTALL:-0}"
REMOVE_INSTALL="${REMOVE_INSTALL:-0}"
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

fresh_prefix() {
  [ "$FRESH_INSTALL" = "1" ] || return 0
  [ "$LAUNCHER_ONLY" != "1" ] || die "--fresh cannot be used with --launcher-only"

  need readlink
  need date
  local resolved_prefix resolved_home resolved_cache script_dir backup_path backup_stamp
  resolved_prefix="$(readlink -m -- "$PREFIX")" || die "could not resolve prefix path"
  resolved_home="$(readlink -m -- "$HOME")" || die "could not resolve home path"
  resolved_cache="$(readlink -m -- "$CACHE_DIR")" || die "could not resolve cache path"
  script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)" || die "could not resolve installer directory"

  if [ -e "$PREFIX" ] || [ -L "$PREFIX" ]; then
    [ -d "$PREFIX" ] || die "existing prefix is not a directory: $PREFIX"
    [ "$resolved_prefix" != "/" ] || die "refusing to fresh-install the root directory"
    [ "$resolved_prefix" != "$resolved_home" ] || die "refusing to fresh-install the home directory"
    case "$resolved_home/" in
      "$resolved_prefix/"*) die "refusing to move a directory containing the home directory" ;;
    esac
    case "$script_dir/" in
      "$resolved_prefix/"*) die "refusing to move a directory containing the installer" ;;
    esac
    case "$resolved_prefix/" in
      "$script_dir/"*) die "refusing to move a prefix inside the installer directory" ;;
    esac
  else
    log "fresh install requested; no existing prefix to back up"
  fi

  [ "$resolved_cache" != "/" ] || die "refusing to clear the root directory as installer cache"
  [ "$resolved_cache" != "$resolved_home" ] || die "refusing to clear the home directory as installer cache"
  case "$resolved_home/" in
    "$resolved_cache/"*) die "refusing to clear a cache directory containing the home directory" ;;
  esac
  case "$resolved_prefix/" in
    "$resolved_cache/"*) die "refusing to clear a cache directory containing the prefix" ;;
  esac
  case "$resolved_cache/" in
    "$resolved_prefix/"*) die "refusing to clear a cache directory inside the prefix" ;;
  esac
  case "$script_dir/" in
    "$resolved_cache/"*) die "refusing to clear a cache directory containing the installer" ;;
  esac
  case "$resolved_cache/" in
    "$script_dir/"*) die "refusing to clear a cache directory inside the installer directory" ;;
  esac

  if [ -e "$PREFIX" ] || [ -L "$PREFIX" ]; then
    backup_stamp="$(date '+%Y%m%d-%H%M%S')" || die "could not create backup timestamp"
    backup_path="${PREFIX}.backup-${backup_stamp}"
    if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
      backup_path="${backup_path}-$$"
    fi
    [ ! -e "$backup_path" ] && [ ! -L "$backup_path" ] \
      || die "prefix backup path already exists: $backup_path"
    mv -T -- "$PREFIX" "$backup_path" || die "could not back up existing prefix to $backup_path"
    log "existing prefix moved to backup: $backup_path"
  fi

  log "clearing installer cache: $resolved_cache"
  rm -rf -- "$resolved_cache" || die "could not clear installer cache: $resolved_cache"
  mkdir -p -- "$resolved_cache" || die "could not recreate installer cache: $resolved_cache"
}

remove_file() { # remove_file <path> [system]
  local path="$1" system="${2:-0}"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ "$system" = "1" ] && [ "$EUID" -ne 0 ]; then
    need sudo
    sudo rm -f -- "$path" || die "could not remove $path"
  else
    rm -f -- "$path" || die "could not remove $path"
  fi
  log "removed $path"
}

remove_empty_dir() { # remove_empty_dir <path> [system]
  local path="$1" system="${2:-0}" contents
  [ -d "$path" ] && [ ! -L "$path" ] || return 0
  if [ "$system" = "1" ]; then
    if [ "$EUID" -eq 0 ]; then
      rmdir --ignore-fail-on-non-empty -- "$path" || die "could not remove empty directory: $path"
    else
      need sudo
      sudo rmdir --ignore-fail-on-non-empty -- "$path" \
        || die "could not remove empty directory: $path"
    fi
    return 0
  fi
  contents="$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" \
    || die "could not inspect directory: $path"
  [ -z "$contents" ] || return 0
  rmdir -- "$path" || die "could not remove empty directory: $path"
}

refuse_system_tree() { # refuse_system_tree <resolved-path> <label>
  local path="$1" label="$2" protected
  for protected in /usr /etc /var /bin /sbin /lib /lib64 /boot /dev /proc /sys /run; do
    [ "$path" != "$protected" ] \
      || die "refusing to remove $protected as $label"
    case "$protected/" in
      "$path/"*) die "refusing to remove a path containing protected directory $protected" ;;
    esac
    case "$path/" in
      "$protected/"*) die "refusing to remove $label inside protected directory $protected" ;;
    esac
  done
  for protected in /tmp /home /root /mnt /media /opt /srv; do
    [ "$path" != "$protected" ] \
      || die "refusing to remove $protected as $label"
    case "$protected/" in
      "$path/"*) die "refusing to remove a path containing protected directory $protected" ;;
    esac
  done
}

remove_mime_association() {
  local mimeapps="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list" tmp
  [ -f "$mimeapps" ] || return 0
  [ ! -L "$mimeapps" ] || die "refusing to replace symlinked MIME configuration: $mimeapps"

  tmp="$(mktemp "${mimeapps}.byond-remove.XXXXXX")" \
    || die "could not create temporary MIME configuration"
  if ! awk '
    function remove_byond(value, count, ids, i, result, found) {
      count = split(value, ids, ";")
      for (i = 1; i <= count; i++) {
        if (ids[i] == "byond.desktop" || ids[i] == "byond-url-handler.desktop")
          found = 1
      }
      if (!found)
        return value
      for (i = 1; i <= count; i++) {
        if (ids[i] != "" && ids[i] != "byond.desktop" && ids[i] != "byond-url-handler.desktop")
          result = result ids[i] ";"
      }
      return result
    }
    /^\[/ { section = $0; print; next }
    section == "[Default Applications]" || section == "[Added Associations]" {
      separator = index($0, "=")
      if (separator && substr($0, 1, separator - 1) == "x-scheme-handler/byond") {
        key = substr($0, 1, separator - 1)
        value = remove_byond(substr($0, separator + 1))
        if (value != "")
          print key "=" value
        next
      }
    }
    { print }
  ' "$mimeapps" > "$tmp"; then
    rm -f -- "$tmp"
    die "could not update MIME configuration: $mimeapps"
  fi

  if cmp -s -- "$mimeapps" "$tmp"; then
    rm -f -- "$tmp"
  else
    chmod --reference="$mimeapps" "$tmp" || {
      rm -f -- "$tmp"
      die "could not preserve permissions for $mimeapps"
    }
    mv -f -- "$tmp" "$mimeapps" || {
      rm -f -- "$tmp"
      die "could not update MIME configuration: $mimeapps"
    }
    log "removed BYOND URL association from $mimeapps"
  fi
}

remove_installation() {
  [ "$FRESH_INSTALL" != "1" ] || die "--remove cannot be combined with --fresh"
  [ "$DRY_RUN" != "1" ] || die "--remove cannot be combined with --dry-run"
  [ "$LAUNCHER_ONLY" != "1" ] || die "--remove cannot be combined with --launcher-only"

  need readlink
  need awk
  need cmp
  need mktemp
  need find
  local resolved_prefix resolved_cache resolved_home script_dir
  local user_config user_launcher user_desktop apps_user mimeapps
  local backup backup_suffix
  resolved_prefix="$(readlink -m -- "$PREFIX")" || die "could not resolve prefix path"
  resolved_cache="$(readlink -m -- "$CACHE_DIR")" || die "could not resolve cache path"
  resolved_home="$(readlink -m -- "$HOME")" || die "could not resolve home path"
  script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)" || die "could not resolve installer directory"

  [ "$resolved_prefix" != "/" ] || die "refusing to remove the root directory as prefix"
  [ "$resolved_prefix" != "$resolved_home" ] || die "refusing to remove the home directory as prefix"
  refuse_system_tree "$resolved_prefix" prefix
  case "$resolved_home/" in
    "$resolved_prefix/"*) die "refusing to remove a prefix containing the home directory" ;;
  esac
  case "$script_dir/" in
    "$resolved_prefix/"*) die "refusing to remove a prefix containing the installer" ;;
  esac
  case "$resolved_prefix/" in
    "$script_dir/"*) die "refusing to remove a prefix inside the installer directory" ;;
  esac
  [ ! -L "$PREFIX" ] || die "refusing to remove a symlinked prefix: $PREFIX"
  if [ -e "$PREFIX" ] && [ ! -d "$PREFIX" ]; then
    die "prefix exists but is not a directory: $PREFIX"
  fi

  [ "$resolved_cache" != "/" ] || die "refusing to remove the root directory as installer cache"
  [ "$resolved_cache" != "$resolved_home" ] || die "refusing to remove the home directory as installer cache"
  refuse_system_tree "$resolved_cache" cache
  case "$resolved_home/" in
    "$resolved_cache/"*) die "refusing to remove a cache containing the home directory" ;;
  esac
  case "$resolved_prefix/" in
    "$resolved_cache/"*) die "refusing to remove a cache containing the prefix" ;;
  esac
  case "$resolved_cache/" in
    "$resolved_prefix/"*) die "refusing to remove a cache inside the prefix" ;;
  esac
  case "$script_dir/" in
    "$resolved_cache/"*) die "refusing to remove a cache containing the installer" ;;
  esac
  case "$resolved_cache/" in
    "$script_dir/"*) die "refusing to remove a cache inside the installer directory" ;;
  esac
  [ ! -L "$CACHE_DIR" ] || die "refusing to remove a symlinked cache: $CACHE_DIR"
  if [ -e "$CACHE_DIR" ] && [ ! -d "$CACHE_DIR" ]; then
    die "cache path exists but is not a directory: $CACHE_DIR"
  fi

  user_config="${XDG_CONFIG_HOME:-$HOME/.config}/byond/byond-launch.conf"
  user_launcher="${BIN_DIR:-$HOME/.local/bin}/byond-launcher"
  apps_user="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  user_desktop="$apps_user/byond.desktop"
  mimeapps="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
  [ ! -L "$mimeapps" ] || die "refusing to replace symlinked MIME configuration: $mimeapps"

  log "Removal will permanently delete:"
  log "  prefix and timestamped backups: $PREFIX"
  log "  installer cache: $CACHE_DIR"
  log "  user launcher/config/desktop (BYOND machine identity is preserved)"
  log "  system launcher/config/desktop (if present; may require sudo)"
  log "  BYOND URL-handler registration"
  confirm "Continue with complete BYOND removal?" || {
    log "removal cancelled"
    return 0
  }

  if [ -e "$PREFIX" ]; then
    rm -rf -- "$PREFIX" || die "could not remove prefix: $PREFIX"
    log "removed prefix $PREFIX"
  fi
  for backup in "${PREFIX}.backup-"*; do
    [ -e "$backup" ] || [ -L "$backup" ] || continue
    backup_suffix="${backup#"${PREFIX}.backup-"}"
    [[ "$backup_suffix" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]] || continue
    rm -rf -- "$backup" || die "could not remove prefix backup: $backup"
    log "removed prefix backup $backup"
  done
  if [ -e "$CACHE_DIR" ]; then
    rm -rf -- "$CACHE_DIR" || die "could not remove installer cache: $CACHE_DIR"
    log "removed installer cache $CACHE_DIR"
  fi

  remove_file "$user_config"
  remove_file "$user_launcher"
  remove_file "$user_desktop"
  remove_file "$apps_user/byond-url-handler.desktop"
  remove_mime_association

  remove_file "/etc/byond/byond-launch.conf" 1
  remove_file "/usr/local/bin/byond-launcher" 1
  remove_file "/usr/share/applications/byond.desktop" 1

  if command -v update-desktop-database >/dev/null 2>&1; then
    if [ -d "$apps_user" ]; then
      update-desktop-database "$apps_user" \
        || warn "could not refresh user desktop database"
    fi
    if [ -d /usr/share/applications ]; then
      if [ "$EUID" -eq 0 ]; then
        update-desktop-database /usr/share/applications \
          || warn "could not refresh system desktop database"
      elif command -v sudo >/dev/null 2>&1; then
        sudo update-desktop-database /usr/share/applications \
          || warn "could not refresh system desktop database"
      fi
    fi
  fi
  remove_empty_dir "${XDG_CONFIG_HOME:-$HOME/.config}/byond"
  remove_empty_dir "${XDG_DATA_HOME:-$HOME/.local/share}/.byond-wine"
  remove_empty_dir "$(dirname -- "$PREFIX")"
  remove_empty_dir /etc/byond 1
  log "BYOND removal complete"
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)            usage ;;
    --prefix)             PREFIX="$2"; shift 2 ;;
    --fresh)              FRESH_INSTALL=1; shift ;;
    --remove)             REMOVE_INSTALL=1; shift ;;
    --wine)               WINE_BIN="$2"; shift 2 ;;
    --byond-version)      BYOND_VERSION="$2"; shift 2 ;;
    --byond-url)          BYOND_URL="$2"; BYOND_URL_CUSTOM=1; shift 2 ;;
    --no-dxvk)            DXVK_ENABLED=0; shift ;;
    --no-vkd3d)           VKD3D_ENABLED=0; shift ;;
    --vkd3d-version)      VKD3D_VERSION="$2"; shift 2
                          VKD3D_URL="https://github.com/lutris/vkd3d/releases/download/v${VKD3D_VERSION}/vkd3d-${VKD3D_VERSION}.tar.xz" ;;
    --no-d3d-extras)      D3D_EXTRAS_ENABLED=0; shift ;;
    --d3d-extras-version) D3D_EXTRAS_VERSION="$2"; shift 2
                          D3D_EXTRAS_URL="https://github.com/lutris/d3d_extras/releases/download/${D3D_EXTRAS_VERSION}/${D3D_EXTRAS_VERSION}.tar.xz" ;;
    --no-font-patch)      FONT_PATCH=0; shift ;;
    --no-watchdog)        SPACE_WATCHDOG_ENABLED=0; shift ;;
    --math-font)          MATH_FONT="$2"; shift 2 ;;
    --symbola-url)          SYMBOLA_URL="$2"; shift 2 ;;
    --renderer-limit)     WEBVIEW2_RENDERER_LIMIT="$2"; shift 2 ;;
    --repo-base)          REPO_BASE="$2"; shift 2
                          SMOFONT_URL="${REPO_BASE}/extra/fonts/smalle.zip"
                          NTID_URL="${REPO_BASE}/extra/NT-ID.sh"
                          SPACE_HANDLER_URL="${REPO_BASE}/extra/space-handler.sh"
                          FONT_PATCH_SCRIPT_URL="${REPO_BASE}/extra/byond-font-patch.py"
                          SPACE_WATCHDOG_URL="${REPO_BASE}/extra/space-watchdog.sh"
                          ;;
    --user)               SYSTEM_INSTALL=0; shift ;;
    --system)             SYSTEM_INSTALL=1; shift ;;
    --yes)                ASSUME_YES=1; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --launcher-only)      LAUNCHER_ONLY=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "$SPACE_WATCHDOG_ENABLED" in
  0|1) ;;
  *) die "SPACE_WATCHDOG_ENABLED must be 0 or 1" ;;
esac

if [ "$VKD3D_ENABLED" = "auto" ]; then
  VKD3D_ENABLED="$DXVK_ENABLED"
fi
case "$VKD3D_ENABLED" in
  0|1) ;;
  *) die "VKD3D_ENABLED must be 0, 1, or auto" ;;
esac
if [ "$DXVK_ENABLED" != "1" ]; then
  VKD3D_ENABLED=0
fi

export PREFIX WINE_BIN
if [ "$PREFIX" != "/" ]; then PREFIX="${PREFIX%/}"; fi
[ -n "$PREFIX" ] || die "prefix cannot be empty"
[ "$PREFIX" != "/" ] || die "prefix cannot be /"
[ "$FRESH_INSTALL" != "1" ] || [ "$LAUNCHER_ONLY" != "1" ] \
  || die "--fresh cannot be used with --launcher-only"

if [ "$REMOVE_INSTALL" = "1" ]; then
  remove_installation
  exit 0
fi

if [ "$BYOND_URL_CUSTOM" = "0" ]; then
  BYOND_BUILD_SERIES="${BYOND_VERSION%%.*}"
  BYOND_BUILD_NUMBER="${BYOND_VERSION#*.}"
  [ "$BYOND_BUILD_SERIES" != "$BYOND_VERSION" ] && [ -n "$BYOND_BUILD_SERIES" ] \
    && [ -n "$BYOND_BUILD_NUMBER" ] \
    || die "BYOND version must include a build series and build number, such as 516.1667"
  BYOND_URL="https://www.byond.com/download/build/${BYOND_BUILD_SERIES}/${BYOND_VERSION}_byond.exe"
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
log "BYOND standalone installer"
log "  wine        : $WINE_BIN"
log "  prefix      : $PREFIX"
log "  BYOND       : $BYOND_VERSION"
log "  DXVK        : $DXVK_ENABLED (v$DXVK_VERSION)"
log "  VKD3D       : $VKD3D_ENABLED (v$VKD3D_VERSION)"
log "  D3D Extras  : $D3D_EXTRAS_ENABLED ($D3D_EXTRAS_VERSION)"
log "  repo base   : $REPO_BASE"
log "  fresh       : $FRESH_INSTALL"

need "$WINE_BIN"
need winetricks; need curl; need unzip; need tar; need sha256sum
if [ "$VKD3D_ENABLED" = "1" ] || [ "$D3D_EXTRAS_ENABLED" = "1" ]; then need xz; fi
mkdir -p "$CACHE_DIR"

"$WINE_BIN" --version >/dev/null 2>&1 || die "wine binary not runnable: $WINE_BIN"
wine_ver="$("$WINE_BIN" --version 2>/dev/null | sed -E 's/^wine-//' | head -n1)"
log "detected wine: $wine_ver (need >= 10.8, 11.x recommended)"

# ---------------------------------------------------------------------------
# Artifact generation (config + launcher + desktop entry)
# ---------------------------------------------------------------------------
dll_override_names=()
if [ "$DXVK_ENABLED" = "1" ]; then
  dll_override_names+=(d3d10core d3d11 dxgi)
fi
if [ "$VKD3D_ENABLED" = "1" ]; then
  dll_override_names+=(d3d12 d3d12core)
fi
if [ "$D3D_EXTRAS_ENABLED" = "1" ]; then
  dll_override_names+=(
    d3dx10_33 d3dx10_34 d3dx10_35 d3dx10_36 d3dx10_37 d3dx10_38
    d3dx10_39 d3dx10_40 d3dx10_41 d3dx10_42 d3dx10_43 d3dx10
    d3dx11_42 d3dx11_43
    d3dx9_24 d3dx9_25 d3dx9_26 d3dx9_27 d3dx9_28 d3dx9_29 d3dx9_30
    d3dx9_31 d3dx9_32 d3dx9_33 d3dx9_34 d3dx9_35 d3dx9_36 d3dx9_37
    d3dx9_38 d3dx9_39 d3dx9_40 d3dx9_41 d3dx9_42 d3dx9_43
    d3dcompiler_33 d3dcompiler_34 d3dcompiler_35 d3dcompiler_36
    d3dcompiler_37 d3dcompiler_38 d3dcompiler_39 d3dcompiler_40
    d3dcompiler_41 d3dcompiler_42 d3dcompiler_43 d3dcompiler_46
    d3dcompiler_47
  )
fi
dll_overrides=""
if [ "${#dll_override_names[@]}" -gt 0 ]; then
  dll_overrides="$(IFS=,; printf '%s' "${dll_override_names[*]}")=n"
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

# DLL overrides for the enabled DXVK, VKD3D, and D3D Extras components.
WINEDLLOVERRIDES="$dll_overrides"

# Environment (matches a fast, well-behaved configuration).
WINEDEBUG="-all"
DXVK_LOG_LEVEL="error"
WINEESYNC="1"
WINEFSYNC="1"
WINE_LARGE_ADDRESS_AWARE="1"

# Extra arguments appended to the wine command.
GAME_ARGS=""

# Set to 1 to run the installed Space Watchdog with BYOND.
SPACE_WATCHDOG_ENABLED="$SPACE_WATCHDOG_ENABLED"

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

case "${SPACE_WATCHDOG_ENABLED:-0}" in
  0) ;;
  1)
    watchdog="$WINEPREFIX/space-watchdog.sh"
    [ -x "$watchdog" ] || {
      echo "byond-launcher: watchdog is enabled but missing or not executable: $watchdog" >&2
      exit 1
    }
    ;;
  *)
    echo "byond-launcher: SPACE_WATCHDOG_ENABLED must be 0 or 1" >&2
    exit 1
    ;;
esac

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
if [ "${SPACE_WATCHDOG_ENABLED:-0}" = "1" ]; then
  WINE="$WINE_BIN" "$watchdog" --prefix "$WINEPREFIX" >>"$WINEPREFIX/space-watchdog.log" 2>&1 &
fi
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
fresh_prefix
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
wine_run "$CACHE_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64.exe" /install >/dev/null 2>&1 \
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

if [ "$VKD3D_ENABLED" = "1" ]; then
  log "installing VKD3D v$VKD3D_VERSION"
  vkd3d_archive="$CACHE_DIR/vkd3d-${VKD3D_VERSION}.tar.xz"
  download "$VKD3D_URL" "$vkd3d_archive"
  rm -rf "$CACHE_DIR/vkd3d"
  mkdir -p "$CACHE_DIR/vkd3d"
  tar -xJf "$vkd3d_archive" -C "$CACHE_DIR/vkd3d"
  vkd3d_root="$CACHE_DIR/vkd3d/vkd3d-${VKD3D_VERSION}"
  [ -f "$vkd3d_root/x64/d3d12.dll" ] && [ -f "$vkd3d_root/x64/d3d12core.dll" ] \
    && [ -f "$vkd3d_root/x86/d3d12.dll" ] && [ -f "$vkd3d_root/x86/d3d12core.dll" ] \
    || die "VKD3D archive has an unexpected layout"
  cp -f --remove-destination "$vkd3d_root/x64/"*.dll "$PREFIX/drive_c/windows/system32/"
  cp -f --remove-destination "$vkd3d_root/x86/"*.dll "$PREFIX/drive_c/windows/syswow64/"
fi

if [ "$D3D_EXTRAS_ENABLED" = "1" ]; then
  log "installing D3D Extras $D3D_EXTRAS_VERSION"
  d3d_extras_archive="$CACHE_DIR/d3d-extras-${D3D_EXTRAS_VERSION}.tar.xz"
  download "$D3D_EXTRAS_URL" "$d3d_extras_archive"
  rm -rf "$CACHE_DIR/d3d-extras"
  mkdir -p "$CACHE_DIR/d3d-extras"
  tar -xJf "$d3d_extras_archive" -C "$CACHE_DIR/d3d-extras"
  d3d_extras_root="$CACHE_DIR/d3d-extras/$D3D_EXTRAS_VERSION"
  [ -f "$d3d_extras_root/x64/d3dcompiler_47.dll" ] \
    && [ -f "$d3d_extras_root/x32/d3dcompiler_47.dll" ] \
    || die "D3D Extras archive has an unexpected layout"
  cp -f --remove-destination "$d3d_extras_root/x64/"*.dll "$PREFIX/drive_c/windows/system32/"
  cp -f --remove-destination "$d3d_extras_root/x32/"*.dll "$PREFIX/drive_c/windows/syswow64/"
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

if [ "$SPACE_WATCHDOG_ENABLED" = "1" ]; then
  download "$SPACE_WATCHDOG_URL" "$CACHE_DIR/space-watchdog.sh"
  place "$CACHE_DIR/space-watchdog.sh" "$PREFIX/space-watchdog.sh" 755 0
fi

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
