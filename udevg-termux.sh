#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="yuru7"
REPO_NAME="udev-gothic"
API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
TRUSTED_ASSET_PREFIX="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/"
TARGET_DIR="${HOME}/.termux"
TARGET_FONT="${TARGET_DIR}/font.ttf"
CACHE_DIR="${HOME}/.cache/udevgothic"
DEFAULT_FONT_NAME="UDEVGothicNF-Regular.ttf"
MAX_UNCOMPRESSED_BYTES=$((512 * 1024 * 1024))
FONT_NAME=""
FONT_SPECIFIED=0
PRESET=""
PRESET_SPECIFIED=0
LIST_ONLY=0
FORCE=0
SKIP_VERIFY=0
REQUIRE_VERIFY=0
TMP_DIR=""

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  -f, --font NAME      Font file name in release archive (exact or partial)
  -p, --preset PRESET  Short preset (e.g. nf, nflg, 35nf, 35nflg, hs)
  -l, --list           Show available packages/presets and exit
  -y, --yes            Skip confirmation prompt
      --no-verify      Skip SHA256 verification (not recommended)
      --require-verify Fail if SHA256 digest is unavailable
  -h, --help           Show this help

Examples:
  $0
  $0 --preset nf
  $0 --preset 35nflg-bold
  $0 --font UDEVGothic35HS-Regular.ttf
  curl -fsSLo /tmp/udevg-termux.sh <raw-script-url> && bash /tmp/udevg-termux.sh --preset nf --yes

Cache:
  Downloaded zip files are cached in: ${CACHE_DIR}
USAGE
}

log() {
  printf '[*] %s\n' "$*"
}

is_termux_env() {
  [ -d "/data/data/com.termux/files/usr" ]
}

in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

termux_package_for_cmd() {
  case "$1" in
    curl) printf '%s\n' 'curl' ;;
    jq) printf '%s\n' 'jq' ;;
    unzip) printf '%s\n' 'unzip' ;;
    find) printf '%s\n' 'findutils' ;;
    sha256sum|install) printf '%s\n' 'coreutils' ;;
    *) return 1 ;;
  esac
}

ensure_dependencies() {
  local required_cmds=("curl" "jq" "sha256sum" "unzip" "find" "install")
  local missing_cmds=()
  local cmd
  local pkg_name
  local packages_to_install=()

  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
    fi
  done

  [ "${#missing_cmds[@]}" -eq 0 ] && return 0

  if is_termux_env && command -v pkg >/dev/null 2>&1; then
    for cmd in "${missing_cmds[@]}"; do
      pkg_name="$(termux_package_for_cmd "$cmd" || true)"
      if [ -z "$pkg_name" ]; then
        echo "Error: Missing dependency '$cmd', but no package mapping was found." >&2
        return 1
      fi
      if ! in_list "$pkg_name" "${packages_to_install[@]}"; then
        packages_to_install+=("$pkg_name")
      fi
    done

    log "Missing dependencies detected: ${missing_cmds[*]}"
    log "Installing packages: ${packages_to_install[*]}"
    local install_log=""
    if ! install_log="$(mktemp "${TMPDIR:-/tmp}/udevg-pkg-install.XXXXXX.log")"; then
      echo "Error: Failed to create a temporary log file for pkg output." >&2
      return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive pkg install -y "${packages_to_install[@]}" > "${install_log}" 2>&1; then
      echo "Error: Failed to install dependencies via pkg." >&2
      if [ -s "${install_log}" ]; then
        echo "---- pkg output (last 80 lines) ----" >&2
        tail -n 80 "${install_log}" >&2 || true
        echo "------------------------------------" >&2
      fi
      rm -f "${install_log}"
      return 1
    fi
    rm -f "${install_log}"

    for cmd in "${missing_cmds[@]}"; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Dependency '$cmd' is still missing after installation." >&2
        return 1
      fi
    done
    return 0
  fi

  echo "Error: Missing required dependencies: ${missing_cmds[*]}" >&2
  echo "Install them manually and re-run this script." >&2
  return 1
}

confirm() {
  local prompt="$1"
  local answer=""

  if [ -r /dev/tty ]; then
    read -r -p "$prompt [y/N]: " answer </dev/tty || return 1
  else
    echo "Error: Non-interactive mode detected. Re-run with --yes." >&2
    return 1
  fi

  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f|--font)
        [ "$#" -lt 2 ] && { echo "Error: --font requires an argument" >&2; exit 1; }
        FONT_NAME="$2"
        FONT_SPECIFIED=1
        shift 2
        ;;
      -p|--preset)
        [ "$#" -lt 2 ] && { echo "Error: --preset requires an argument" >&2; exit 1; }
        PRESET="$2"
        PRESET_SPECIFIED=1
        shift 2
        ;;
      -l|--list)
        LIST_ONLY=1
        shift
        ;;
      -y|--yes)
        FORCE=1
        shift
        ;;
      --no-verify)
        SKIP_VERIFY=1
        shift
        ;;
      --require-verify)
        REQUIRE_VERIFY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Error: unknown option '$1'" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

is_tty_available() {
  [ -r /dev/tty ]
}

zip_name_from_url() {
  printf '%s\n' "${1##*/}"
}

normalize_text() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]//g'
}

collect_zip_urls_from_metadata() {
  local metadata="$1"
  printf '%s\n' "$metadata" \
    | jq -r '.assets[]? | select((.browser_download_url // "") | test("\\.zip$")) | .browser_download_url' \
    | sort -u
}

is_trusted_asset_url() {
  local url="$1"
  case "$url" in
    "${TRUSTED_ASSET_PREFIX}"*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_zip_urls() {
  local urls="$1"
  local url

  while IFS= read -r url; do
    [ -z "$url" ] && continue
    if ! is_trusted_asset_url "$url"; then
      echo "Error: Untrusted asset URL in release metadata: $url" >&2
      return 1
    fi
  done <<EOF_URLS
$urls
EOF_URLS
}

sha256_from_digest() {
  local digest="$1"
  local hash

  case "$digest" in
    sha256:*) hash="${digest#sha256:}" ;;
    *) return 1 ;;
  esac

  hash="$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')"
  if ! printf '%s' "$hash" | grep -Eq '^[0-9a-f]{64}$'; then
    return 1
  fi

  printf '%s\n' "$hash"
}

sha256_for_asset_url() {
  local metadata="$1"
  local url="$2"
  local digest
  local hash

  digest="$(printf '%s\n' "$metadata" \
    | jq -r --arg url "$url" '.assets[]? | select(.browser_download_url == $url) | (.digest // empty)' \
    | head -n1)"

  [ -z "$digest" ] && return 1
  hash="$(sha256_from_digest "$digest" || true)"
  [ -z "$hash" ] && return 1
  printf '%s\n' "$hash"
}

verify_file_sha256() {
  local file_path="$1"
  local expected_sha="$2"
  local actual_sha

  actual_sha="$(sha256sum "$file_path" | awk '{print tolower($1)}')"
  [ "$actual_sha" = "$expected_sha" ]
}

archive_uncompressed_size_bytes() {
  local archive_path="$1"
  unzip -l "$archive_path" \
    | awk 'NR > 3 && $1 ~ /^[0-9]+$/ && NF >= 4 {sum += $1} END {print sum + 0}'
}

validate_archive_entries() {
  local archive_path="$1"
  local entry

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if printf '%s\n' "$entry" | grep -Eq '(^/|\\|(^|/)\.\.(/|$))'; then
      echo "Error: Archive contains unsafe path: $entry" >&2
      return 1
    fi
  done <<EOF_ENTRIES
$(unzip -Z -1 "$archive_path")
EOF_ENTRIES
}

enforce_archive_limits() {
  local archive_path="$1"
  local uncompressed_size

  uncompressed_size="$(archive_uncompressed_size_bytes "$archive_path")"
  if [ "$uncompressed_size" -gt "$MAX_UNCOMPRESSED_BYTES" ]; then
    echo "Error: Archive is too large when uncompressed (${uncompressed_size} bytes)." >&2
    echo "Limit: ${MAX_UNCOMPRESSED_BYTES} bytes." >&2
    return 1
  fi
}

download_zip_with_cache() {
  local url="$1"
  local output_path="$2"
  local expected_sha256="${3:-}"
  local cache_path
  local tmp_path

  mkdir -p "$CACHE_DIR"
  chmod 700 "$CACHE_DIR" 2>/dev/null || true
  cache_path="${CACHE_DIR}/$(zip_name_from_url "$url")"

  if [ -s "$cache_path" ]; then
    if ! unzip -tqq "$cache_path" >/dev/null 2>&1; then
      echo "Warning: Invalid cache detected. Re-downloading: ${cache_path}" >&2
      rm -f "$cache_path"
    elif [ -n "$expected_sha256" ] && [ "$SKIP_VERIFY" -ne 1 ] && ! verify_file_sha256 "$cache_path" "$expected_sha256"; then
      echo "Warning: Cache SHA256 mismatch. Re-downloading: ${cache_path}" >&2
      rm -f "$cache_path"
    else
      log "Using cache: ${cache_path}"
    fi
  fi

  if [ ! -s "$cache_path" ]; then
    tmp_path="${cache_path}.tmp.$$"
    log "Downloading: ${url}"
    if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 -o "$tmp_path" "$url"; then
      rm -f "$tmp_path"
      return 1
    fi

    if ! unzip -tqq "$tmp_path" >/dev/null 2>&1; then
      rm -f "$tmp_path"
      echo "Error: Downloaded file is not a valid zip archive." >&2
      return 1
    fi

    if [ -n "$expected_sha256" ] && [ "$SKIP_VERIFY" -ne 1 ] && ! verify_file_sha256 "$tmp_path" "$expected_sha256"; then
      rm -f "$tmp_path"
      echo "Error: SHA256 verification failed for downloaded asset." >&2
      return 1
    fi

    mv "$tmp_path" "$cache_path"
    chmod 600 "$cache_path" 2>/dev/null || true
  fi

  cp -f "$cache_path" "$output_path"
}

bundle_key_from_zip_url() {
  local name
  name="$(zip_name_from_url "$1")"

  case "$name" in
    UDEVGothic_NF_v*.zip) printf '%s\n' 'nf' ;;
    UDEVGothic_HS_v*.zip) printf '%s\n' 'hs' ;;
    UDEVGothic_v*.zip) printf '%s\n' 'standard' ;;
    *)
      case "$(normalize_text "$name")" in
        *nf*) printf '%s\n' 'nf' ;;
        *hs*) printf '%s\n' 'hs' ;;
        *) printf '%s\n' 'standard' ;;
      esac
      ;;
  esac
}

bundle_label_from_key() {
  case "$1" in
    standard) printf '%s\n' 'standard' ;;
    nf) printf '%s\n' 'NF' ;;
    hs) printf '%s\n' 'HS' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

resolve_zip_url_by_bundle_key() {
  local urls="$1"
  local key="$2"
  local url
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    if [ "$(bundle_key_from_zip_url "$url")" = "$key" ]; then
      printf '%s\n' "$url"
      return 0
    fi
  done <<EOF_URLS
$urls
EOF_URLS
  return 1
}

pick_default_zip_url() {
  local urls="$1"
  local url
  url="$(resolve_zip_url_by_bundle_key "$urls" "standard" || true)"
  if [ -n "$url" ]; then
    printf '%s\n' "$url"
    return 0
  fi
  printf '%s\n' "$urls" | head -n1
}

extract_bundle_key_from_text() {
  local text_norm
  local has_hs=0
  local has_nf=0

  text_norm="$(normalize_text "$1")"
  printf '%s' "$text_norm" | grep -Fq 'hs' && has_hs=1 || true
  printf '%s' "$text_norm" | grep -Fq 'nf' && has_nf=1 || true

  if [ "$has_hs" -eq 1 ] && [ "$has_nf" -eq 1 ]; then
    echo "Error: text contains both HS and NF tokens: $1" >&2
    exit 1
  fi

  if [ "$has_hs" -eq 1 ]; then
    printf '%s\n' 'hs'
    return 0
  fi

  if [ "$has_nf" -eq 1 ]; then
    printf '%s\n' 'nf'
    return 0
  fi

  printf '%s\n' 'standard'
}

choose_bundle_interactively() {
  local urls="$1"
  local default_url="$2"
  local choice=""
  local picked=""
  local i=1
  local max_choice=0
  local url
  local key
  local label
  local name
  local shown=""

  echo "Available variants:" >&2
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    key="$(bundle_key_from_zip_url "$url")"
    case " $shown " in
      *" ${key} "*) continue ;;
    esac
    shown="${shown} ${key}"

    label="$(bundle_label_from_key "$key")"
    name="$(zip_name_from_url "$url")"
    if [ "$url" = "$default_url" ]; then
      printf '  %2d) %s (%s) (default)\n' "$i" "$label" "$name" >&2
    else
      printf '  %2d) %s (%s)\n' "$i" "$label" "$name" >&2
    fi
    i=$((i + 1))
  done <<EOF_URLS
$urls
EOF_URLS

  max_choice=$((i - 1))
  echo "Enter a number (1-${max_choice}), or press Enter for default." >&2
  read -r -p "Select variant number: " choice </dev/tty || return 1

  if [ -z "$choice" ]; then
    printf '%s\n' "$default_url"
    return 0
  fi

  if ! printf '%s' "$choice" | grep -Eq '^[0-9]+$'; then
    echo "Error: Please enter a number." >&2
    return 1
  fi

  i=1
  shown=""
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    key="$(bundle_key_from_zip_url "$url")"
    case " $shown " in
      *" ${key} "*) continue ;;
    esac
    shown="${shown} ${key}"
    if [ "$i" -eq "$choice" ]; then
      picked="$url"
      break
    fi
    i=$((i + 1))
  done <<EOF_URLS
$urls
EOF_URLS

  if [ -z "$picked" ]; then
    echo "Error: Out of range. Select a listed number." >&2
    return 1
  fi

  printf '%s\n' "$picked"
}

list_available_packages() {
  local urls="$1"
  local url
  local key
  local label

  echo "Available packages (latest release):"
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    key="$(bundle_key_from_zip_url "$url")"
    label="$(bundle_label_from_key "$key")"
    printf '  - %-8s %s\n' "$label" "$(zip_name_from_url "$url")"
  done <<EOF_URLS
$urls
EOF_URLS

  echo
  echo "Preset examples:"
  echo "  - standard, lg, 35, 35lg"
  echo "  - nf, nflg, 35nf, 35nflg"
  echo "  - hs, hslg, 35hs, 35hslg"
  echo "  - Optional style suffix: -bold / -italic / -bolditalic"
  echo "    Example: 35nflg-bold"
}

collect_font_names() {
  local extract_dir="$1"
  find "$extract_dir" -type f \( -iname '*.ttf' -o -iname '*.otf' \) \
    | sed -E 's#.*/##' \
    | sort -u
}

pick_default_font_name() {
  local names="$1"
  local first_name
  local first_regular
  local candidate

  if printf '%s\n' "$names" | grep -Fxq "$DEFAULT_FONT_NAME"; then
    printf '%s\n' "$DEFAULT_FONT_NAME"
    return 0
  fi

  for candidate in \
    "UDEVGothic-Regular.ttf" \
    "UDEVGothicNF-Regular.ttf" \
    "UDEVGothicHS-Regular.ttf" \
    "UDEVGothicLG-Regular.ttf" \
    "UDEVGothic35-Regular.ttf" \
    "UDEVGothic35NF-Regular.ttf" \
    "UDEVGothic35HS-Regular.ttf" \
    "UDEVGothic35LG-Regular.ttf"
  do
    if printf '%s\n' "$names" | grep -Fxq "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  first_regular="$(printf '%s\n' "$names" | grep -Ei 'Regular\.(ttf|otf)$' | head -n1 || true)"
  if [ -n "$first_regular" ]; then
    printf '%s\n' "$first_regular"
    return 0
  fi

  first_name="$(printf '%s\n' "$names" | head -n1)"
  if [ -n "$first_name" ]; then
    printf '%s\n' "$first_name"
    return 0
  fi

  return 1
}

resolve_font_name() {
  local names="$1"
  local requested="$2"
  local resolved=""
  local match_count=0
  local line

  resolved="$(printf '%s\n' "$names" | grep -Fix "$requested" | head -n1 || true)"
  if [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  while IFS= read -r line; do
    if printf '%s\n' "$line" | grep -Fqi "$requested"; then
      resolved="$line"
      match_count=$((match_count + 1))
    fi
  done <<EOF_FONTS
$names
EOF_FONTS

  if [ "$match_count" -eq 1 ] && [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

build_font_records() {
  local names="$1"
  local name
  local size_flag
  local token
  local style
  local size
  local width
  local base

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if [[ "$name" =~ ^UDEVGothic(35)?([A-Za-z]*)-(Regular|Bold|Italic|BoldItalic)\.(ttf|otf)$ ]]; then
      size_flag="${BASH_REMATCH[1]}"
      token="${BASH_REMATCH[2]}"
      style="${BASH_REMATCH[3]}"

      if [ -n "$size_flag" ]; then
        size="35"
      else
        size="normal"
      fi

      width="normal"
      if [ -n "$token" ] && [ "${token%LG}" != "$token" ]; then
        width="lg"
        token="${token%LG}"
      fi

      if [ -z "$token" ]; then
        base="standard"
      else
        base="$(normalize_text "$token")"
      fi

      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$base" "$size" "$width" "$style"
    fi
  done <<EOF_FONTS
$names
EOF_FONTS
}

records_unique_field() {
  local records="$1"
  local index="$2"
  [ -z "$records" ] && return 0
  printf '%s\n' "$records" | cut -f"$index" | sort -u
}

filter_records() {
  local records="$1"
  local base="$2"
  local size="$3"
  local width="$4"
  local style="$5"
  local file
  local r_base
  local r_size
  local r_width
  local r_style

  while IFS=$'\t' read -r file r_base r_size r_width r_style; do
    [ -z "$file" ] && continue

    if [ "$base" != "*" ] && [ "$r_base" != "$base" ]; then
      continue
    fi
    if [ "$size" != "*" ] && [ "$r_size" != "$size" ]; then
      continue
    fi
    if [ "$width" != "*" ] && [ "$r_width" != "$width" ]; then
      continue
    fi
    if [ "$style" != "*" ] && [ "$r_style" != "$style" ]; then
      continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$r_base" "$r_size" "$r_width" "$r_style"
  done <<EOF_RECORDS
$records
EOF_RECORDS
}

pick_font_from_records() {
  local records="$1"
  [ -z "$records" ] && return 1
  printf '%s\n' "$records" | cut -f1 | head -n1
}

has_option() {
  local options="$1"
  local value="$2"
  [ -z "$value" ] && return 1
  printf '%s\n' "$options" | grep -Fxq "$value"
}

pick_default_option() {
  local options="$1"
  shift
  local preferred

  for preferred in "$@"; do
    [ -z "$preferred" ] && continue
    if has_option "$options" "$preferred"; then
      printf '%s\n' "$preferred"
      return 0
    fi
  done

  printf '%s\n' "$options" | head -n1
}

option_count() {
  local options="$1"
  printf '%s\n' "$options" | sed '/^$/d' | wc -l | tr -d ' '
}

option_label() {
  local kind="$1"
  local value="$2"

  case "$kind" in
    base)
      case "$value" in
        standard) printf '%s\n' 'standard' ;;
        nf) printf '%s\n' 'NF' ;;
        hs) printf '%s\n' 'HS' ;;
        *) printf '%s\n' "$value" ;;
      esac
      ;;
    size)
      case "$value" in
        normal) printf '%s\n' 'normal' ;;
        35) printf '%s\n' '35' ;;
        *) printf '%s\n' "$value" ;;
      esac
      ;;
    width)
      case "$value" in
        normal) printf '%s\n' 'normal' ;;
        lg) printf '%s\n' 'LG' ;;
        *) printf '%s\n' "$value" ;;
      esac
      ;;
    style)
      printf '%s\n' "$value"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

choose_option_interactively() {
  local kind="$1"
  local prompt="$2"
  local options="$3"
  local default_value="$4"
  local i=1
  local value
  local choice=""
  local picked=""

  echo "$prompt" >&2
  while IFS= read -r value; do
    [ -z "$value" ] && continue
    if [ "$value" = "$default_value" ]; then
      printf '  %2d) %s (default)\n' "$i" "$(option_label "$kind" "$value")" >&2
    else
      printf '  %2d) %s\n' "$i" "$(option_label "$kind" "$value")" >&2
    fi
    i=$((i + 1))
  done <<EOF_OPTIONS
$options
EOF_OPTIONS

  echo "Press Enter to use default." >&2
  read -r -p "Select number: " choice </dev/tty || return 1

  if [ -z "$choice" ]; then
    printf '%s\n' "$default_value"
    return 0
  fi

  if ! printf '%s' "$choice" | grep -Eq '^[0-9]+$'; then
    echo "Error: Please enter a number." >&2
    return 1
  fi

  picked="$(sed -n "${choice}p" <<EOF_OPTIONS
$options
EOF_OPTIONS
)"

  if [ -z "$picked" ]; then
    echo "Error: Out of range. Select a listed number." >&2
    return 1
  fi

  printf '%s\n' "$picked"
}

parse_preset_preferences() {
  local preset_text="$1"
  local preset_norm
  local has_hs=0
  local has_nf=0
  local has_lg=0
  local has_35=0
  local has_bold=0
  local has_italic=0
  local has_bolditalic=0
  local bundle="standard"
  local size="normal"
  local width="normal"
  local style="Regular"

  preset_norm="$(normalize_text "$preset_text")"

  printf '%s' "$preset_norm" | grep -Fq 'hs' && has_hs=1 || true
  printf '%s' "$preset_norm" | grep -Fq 'nf' && has_nf=1 || true
  printf '%s' "$preset_norm" | grep -Fq 'lg' && has_lg=1 || true
  printf '%s' "$preset_norm" | grep -Fq '35' && has_35=1 || true
  printf '%s' "$preset_norm" | grep -Fq 'bolditalic' && has_bolditalic=1 || true
  printf '%s' "$preset_norm" | grep -Fq 'bold' && has_bold=1 || true
  printf '%s' "$preset_norm" | grep -Fq 'italic' && has_italic=1 || true

  if [ "$has_hs" -eq 1 ] && [ "$has_nf" -eq 1 ]; then
    echo "Error: preset cannot include both HS and NF: $preset_text" >&2
    exit 1
  fi

  if [ "$has_hs" -eq 1 ]; then
    bundle="hs"
  elif [ "$has_nf" -eq 1 ]; then
    bundle="nf"
  fi

  if [ "$has_35" -eq 1 ]; then
    size="35"
  fi

  if [ "$has_lg" -eq 1 ]; then
    width="lg"
  fi

  if [ "$has_bolditalic" -eq 1 ] || { [ "$has_bold" -eq 1 ] && [ "$has_italic" -eq 1 ]; }; then
    style="BoldItalic"
  elif [ "$has_bold" -eq 1 ]; then
    style="Bold"
  elif [ "$has_italic" -eq 1 ]; then
    style="Italic"
  fi

  printf '%s\t%s\t%s\t%s\n' "$bundle" "$size" "$width" "$style"
}

main() {
  parse_args "$@"

  ensure_dependencies

  if ! is_termux_env; then
    echo "Warning: This does not look like Termux. Continuing anyway." >&2
  fi

  if [ "$SKIP_VERIFY" -eq 1 ]; then
    echo "Warning: SHA256 verification is disabled (--no-verify)." >&2
  fi
  if [ "$SKIP_VERIFY" -eq 1 ] && [ "$REQUIRE_VERIFY" -eq 1 ]; then
    echo "Error: --no-verify and --require-verify cannot be used together." >&2
    exit 1
  fi

  if [ "$FONT_SPECIFIED" -eq 1 ] && [ "$PRESET_SPECIFIED" -eq 1 ]; then
    echo "Warning: --font is set, so --preset is ignored." >&2
  fi

  log "Fetching latest release metadata..."
  local metadata
  metadata="$(curl -fsSL --proto '=https' --tlsv1.2 "$API_URL")"

  local zip_urls
  zip_urls="$(collect_zip_urls_from_metadata "$metadata")"
  if [ -z "$zip_urls" ]; then
    echo "Error: Could not find a zip asset in latest release" >&2
    exit 1
  fi
  validate_zip_urls "$zip_urls"

  if [ "$LIST_ONLY" -eq 1 ]; then
    list_available_packages "$zip_urls"
    exit 0
  fi

  local default_zip_url
  default_zip_url="$(pick_default_zip_url "$zip_urls")"

  local preset_bundle="standard"
  local preset_size="normal"
  local preset_width="normal"
  local preset_style="Regular"
  if [ "$PRESET_SPECIFIED" -eq 1 ]; then
    IFS=$'\t' read -r preset_bundle preset_size preset_width preset_style <<< "$(parse_preset_preferences "$PRESET")"
  fi

  local zip_url=""
  if [ "$FONT_SPECIFIED" -eq 1 ]; then
    local font_bundle
    font_bundle="$(extract_bundle_key_from_text "$FONT_NAME")"
    zip_url="$(resolve_zip_url_by_bundle_key "$zip_urls" "$font_bundle" || true)"
    [ -z "$zip_url" ] && zip_url="$default_zip_url"
  elif [ "$PRESET_SPECIFIED" -eq 1 ]; then
    zip_url="$(resolve_zip_url_by_bundle_key "$zip_urls" "$preset_bundle" || true)"
    [ -z "$zip_url" ] && zip_url="$default_zip_url"
  else
    if is_tty_available; then
      while :; do
        zip_url="$(choose_bundle_interactively "$zip_urls" "$default_zip_url")" || true
        if [ -n "$zip_url" ]; then
          break
        fi
      done
    else
      zip_url="$default_zip_url"
      echo "Warning: Non-interactive mode. Using default variant: $(bundle_label_from_key "$(bundle_key_from_zip_url "$zip_url")")" >&2
    fi
  fi

  if ! is_trusted_asset_url "$zip_url"; then
    echo "Error: Selected asset URL is not trusted: $zip_url" >&2
    exit 1
  fi

  local expected_sha256=""
  if [ "$SKIP_VERIFY" -ne 1 ]; then
    expected_sha256="$(sha256_for_asset_url "$metadata" "$zip_url" || true)"
    if [ -z "$expected_sha256" ]; then
      if [ "$REQUIRE_VERIFY" -eq 1 ]; then
        echo "Error: Could not get SHA256 digest for selected asset from release metadata." >&2
        exit 1
      fi
      echo "Warning: Could not get SHA256 digest for selected asset from release metadata." >&2
      echo "Warning: Continuing without SHA256 verification. Use --require-verify to fail instead." >&2
    fi
  fi

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR:-}"' EXIT

  local zip_path
  zip_path="${TMP_DIR}/font.zip"

  download_zip_with_cache "$zip_url" "$zip_path" "$expected_sha256"

  log "Extracting archive..."
  validate_archive_entries "$zip_path"
  enforce_archive_limits "$zip_path"
  unzip -q "$zip_path" -d "$TMP_DIR/extract"

  local font_names
  font_names="$(collect_font_names "$TMP_DIR/extract")"
  if [ -z "$font_names" ]; then
    echo "Error: No font files (.ttf/.otf) were found in archive" >&2
    exit 1
  fi

  if [ "$FONT_SPECIFIED" -eq 1 ]; then
    local resolved_name
    resolved_name="$(resolve_font_name "$font_names" "$FONT_NAME" || true)"
    if [ -z "$resolved_name" ]; then
      echo "Error: '${FONT_NAME}' did not match any font in archive" >&2
      echo "Available fonts:" >&2
      printf '%s\n' "$font_names" >&2
      exit 1
    fi
    FONT_NAME="$resolved_name"
  else
    local records
    records="$(build_font_records "$font_names")"

    if [ -z "$records" ]; then
      FONT_NAME="$(pick_default_font_name "$font_names")"
    else
      local selected_base
      local selected_size
      local selected_width
      local selected_style
      local base_options
      local size_options
      local width_options
      local style_options
      local filtered
      local default_base

      default_base="$(bundle_key_from_zip_url "$zip_url")"
      if [ "$PRESET_SPECIFIED" -eq 1 ]; then
        default_base="$preset_bundle"
      fi

      base_options="$(records_unique_field "$records" 2)"
      selected_base="$(pick_default_option "$base_options" "$default_base" "standard" "nf" "hs")"

      if [ "$PRESET_SPECIFIED" -eq 0 ] && is_tty_available && [ "$(option_count "$base_options")" -gt 1 ]; then
        while :; do
          selected_base="$(choose_option_interactively "base" "Choose family:" "$base_options" "$selected_base")" || true
          if [ -n "$selected_base" ]; then
            break
          fi
        done
      fi

      filtered="$(filter_records "$records" "$selected_base" "*" "*" "*")"
      size_options="$(records_unique_field "$filtered" 3)"
      if [ "$PRESET_SPECIFIED" -eq 1 ]; then
        selected_size="$(pick_default_option "$size_options" "$preset_size" "normal" "35")"
      else
        selected_size="$(pick_default_option "$size_options" "normal" "35")"
      fi

      if [ "$PRESET_SPECIFIED" -eq 0 ] && is_tty_available && [ "$(option_count "$size_options")" -gt 1 ]; then
        while :; do
          selected_size="$(choose_option_interactively "size" "Choose size:" "$size_options" "$selected_size")" || true
          if [ -n "$selected_size" ]; then
            break
          fi
        done
      fi

      filtered="$(filter_records "$filtered" "*" "$selected_size" "*" "*")"
      width_options="$(records_unique_field "$filtered" 4)"
      if [ "$PRESET_SPECIFIED" -eq 1 ]; then
        selected_width="$(pick_default_option "$width_options" "$preset_width" "normal" "lg")"
      else
        selected_width="$(pick_default_option "$width_options" "normal" "lg")"
      fi

      if [ "$PRESET_SPECIFIED" -eq 0 ] && is_tty_available && [ "$(option_count "$width_options")" -gt 1 ]; then
        while :; do
          selected_width="$(choose_option_interactively "width" "Choose width:" "$width_options" "$selected_width")" || true
          if [ -n "$selected_width" ]; then
            break
          fi
        done
      fi

      filtered="$(filter_records "$filtered" "*" "*" "$selected_width" "*")"
      style_options="$(records_unique_field "$filtered" 5)"
      if [ "$PRESET_SPECIFIED" -eq 1 ]; then
        selected_style="$(pick_default_option "$style_options" "$preset_style" "Regular" "Bold" "Italic" "BoldItalic")"
      else
        selected_style="$(pick_default_option "$style_options" "Regular" "Bold" "Italic" "BoldItalic")"
      fi

      if [ "$PRESET_SPECIFIED" -eq 0 ] && is_tty_available && [ "$(option_count "$style_options")" -gt 1 ]; then
        while :; do
          selected_style="$(choose_option_interactively "style" "Choose style:" "$style_options" "$selected_style")" || true
          if [ -n "$selected_style" ]; then
            break
          fi
        done
      fi

      FONT_NAME="$(pick_font_from_records "$(filter_records "$records" "$selected_base" "$selected_size" "$selected_width" "$selected_style")" || true)"

      if [ -z "$FONT_NAME" ]; then
        FONT_NAME="$(pick_font_from_records "$(filter_records "$records" "$selected_base" "$selected_size" "$selected_width" "Regular")" || true)"
      fi
      if [ -z "$FONT_NAME" ]; then
        FONT_NAME="$(pick_font_from_records "$(filter_records "$records" "$selected_base" "normal" "normal" "Regular")" || true)"
      fi
      if [ -z "$FONT_NAME" ]; then
        FONT_NAME="$(pick_default_font_name "$font_names")"
      fi
    fi
  fi

  if [ "$FORCE" -ne 1 ]; then
    if ! confirm "Install ${FONT_NAME} to ${TARGET_FONT}?"; then
      echo "Canceled."
      exit 0
    fi
  fi

  local selected_font
  selected_font="$(find "$TMP_DIR/extract" -type f -name "$FONT_NAME" | head -n1)"
  if [ -z "$selected_font" ]; then
    selected_font="$(find "$TMP_DIR/extract" -type f -iname "$FONT_NAME" | head -n1)"
  fi

  if [ -z "$selected_font" ]; then
    echo "Error: Font file not found in archive" >&2
    echo "Hint: use --list / --preset / --font" >&2
    exit 1
  fi

  mkdir -p "$TARGET_DIR"
  install -m 644 "$selected_font" "$TARGET_FONT"

  if command -v termux-reload-settings >/dev/null 2>&1; then
    termux-reload-settings
    log "Applied font and reloaded Termux settings."
  else
    log "Applied font. Restart Termux to see changes."
  fi

  log "Done. Active font: $(basename "$selected_font")"
}

main "$@"
