#!/usr/bin/env bash
set -euo pipefail

# ---------- 1) unset previous ----------
if [[ "${INPUT_UNSET_PREVIOUS:-false}" == "true" && -n "${OP_MANAGED_VARIABLES:-}" ]]; then
  echo "Unsetting previous values ..."
  IFS=',' read -ra prev <<< "$OP_MANAGED_VARIABLES"
  for v in "${prev[@]}"; do
    [[ -z "$v" ]] && continue
    echo "Unsetting $v"
    printf '%s=\n' "$v" >> "$GITHUB_ENV"
  done
  printf 'OP_MANAGED_VARIABLES=\n' >> "$GITHUB_ENV"
fi

# ---------- 2) validate auth ----------
has_connect=0
has_sa=0
[[ -n "${OP_CONNECT_HOST:-}" && -n "${OP_CONNECT_TOKEN:-}" ]] && has_connect=1
[[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && has_sa=1

if (( has_connect && has_sa )); then
  echo "::warning::Both service account and Connect credentials provided; Connect takes priority."
elif (( !has_connect && !has_sa )); then
  echo "::error::Authentication error: set OP_SERVICE_ACCOUNT_TOKEN, or both OP_CONNECT_HOST and OP_CONNECT_TOKEN."
  exit 1
fi

if (( has_connect )); then
  echo "Authenticated with Connect."
else
  echo "Authenticated with Service account."
fi

# ---------- 3) optional .env file ----------
if [[ -n "${OP_ENV_FILE:-}" ]]; then
  if [[ -f "$OP_ENV_FILE" ]]; then
    echo "Loading environment variables from file: $OP_ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$OP_ENV_FILE"
    set +a
  else
    echo "::warning::OP_ENV_FILE not found: $OP_ENV_FILE"
  fi
fi

# ---------- 4) install op CLI if missing ----------
cleanup_dir=""

if command -v op >/dev/null 2>&1; then
  echo "op CLI already present: $(command -v op)"
else
  install_dir="${INPUT_INSTALL_DIR:-${RUNNER_TEMP:-/tmp}/op-cli}"
  mkdir -p "$install_dir"

  version="${INPUT_VERSION:-latest}"

  # resolve "latest" / "latest-beta"
  if [[ "$version" == "latest" || "$version" == "latest-beta" ]]; then
    info_json="$(curl -fsSL https://app-updates.agilebits.com/latest)"
    if [[ "$version" == "latest-beta" ]]; then
      channel=beta
    else
      channel=release
    fi
    if command -v jq >/dev/null 2>&1; then
      version="$(printf '%s' "$info_json" | jq -r ".CLI2.${channel}.version")"
    elif command -v python3 >/dev/null 2>&1; then
      version="$(printf '%s' "$info_json" | python3 -c \
        "import json,sys;print(json.load(sys.stdin)['CLI2']['${channel}']['version'])" 2>/dev/null || true)"
    fi
    if [[ -z "$version" || "$version" == "null" ]]; then
      echo "::error::Failed to resolve latest op CLI version (need jq or python3)."
      exit 1
    fi
    echo "Resolved op CLI version: $version"
  fi

  # normalize "v" prefix
  [[ "$version" != v* ]] && version="v$version"

  os="$(uname -s)"

  case "$os" in
    Linux)
      arch_raw="$(uname -m)"
      case "$arch_raw" in
        x86_64|amd64)   arch=amd64 ;;
        aarch64|arm64)  arch=arm64 ;;
        armv7l|armhf)   arch=arm ;;
        i386|i686)      arch=386 ;;
        *) echo "::error::Unsupported architecture: $arch_raw"; exit 1 ;;
      esac
      url="https://cache.agilebits.com/dist/1P/op2/pkg/${version}/op_linux_${arch}_${version}.zip"
      echo "Downloading $url"
      curl -fsSL "$url" -o "$install_dir/op.zip"
      unzip -o "$install_dir/op.zip" -d "$install_dir" >/dev/null
      rm -f "$install_dir/op.zip" "$install_dir/op.sig"
      chmod +x "$install_dir/op"
      ;;
    Darwin)
      url="https://cache.agilebits.com/dist/1P/op2/pkg/${version}/op_apple_universal_${version}.pkg"
      echo "Downloading $url"
      curl -fsSL "$url" -o "$install_dir/op.pkg"
      (
        cd "$install_dir"
        pkgutil --expand op.pkg expanded
        tar -xf expanded/op.pkg/Payload
      )
      rm -rf "$install_dir/op.pkg" "$install_dir/expanded"
      chmod +x "$install_dir/op"
      ;;
    *)
      echo "::error::Unsupported OS: $os"
      exit 1
      ;;
  esac

  echo "$install_dir" >> "$GITHUB_PATH"
  export PATH="$install_dir:$PATH"
  cleanup_dir="$install_dir"
  echo "1Password CLI installed to: $install_dir"
fi

# expose install dir (empty if we didn't install — protects user from rm -rf "")
printf 'install-dir=%s\n' "$cleanup_dir" >> "$GITHUB_OUTPUT"
if [[ -n "$cleanup_dir" ]]; then
  printf 'OP_CLI_INSTALL_DIR=%s\n' "$cleanup_dir" >> "$GITHUB_ENV"
fi

# ---------- 5) load secrets ----------
if ! envs_output="$(op env ls)"; then
  echo "::error::'op env ls' failed. Check your OP_SERVICE_ACCOUNT_TOKEN (or Connect credentials) and network."
  exit 1
fi

# portable split: bash 3.2 on macOS lacks `mapfile`
envs=()
while IFS= read -r line; do
  envs+=("$line")
done <<< "$envs_output"

# filter blank lines
filtered=()
for n in "${envs[@]}"; do
  [[ -n "$n" ]] && filtered+=("$n")
done

if (( ${#filtered[@]} == 0 )); then
  echo "No 1Password references found in environment."
  exit 0
fi

printf '%s\n' "${filtered[@]}"

# Encode a value for use in a GitHub workflow command (e.g. ::add-mask::).
# Commands are parsed line-by-line, so newlines must be encoded as %0A,
# otherwise multi-line secrets would only mask their first line and leak the rest.
encode_workflow_value() {
  local v="$1"
  v="${v//'%'/%25}"
  v="${v//$'\r'/%0D}"
  v="${v//$'\n'/%0A}"
  printf '%s' "$v"
}

managed=()
for name in "${filtered[@]}"; do
  echo "Populating variable: $name"
  ref="${!name:-}"
  [[ -z "$ref" ]] && continue

  if ! val="$(op read "$ref" 2>/dev/null)"; then
    echo "::warning::Failed to resolve $name ($ref)"
    continue
  fi
  [[ -z "$val" ]] && continue

  # Register mask BEFORE writing the value anywhere — so the env block in
  # later steps' logs renders as ***.
  # Mask the full value (encoded) AND each line separately, in case the runner
  # matches against single log lines.
  echo "::add-mask::$(encode_workflow_value "$val")"
  if [[ "$val" == *$'\n'* ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "::add-mask::$(encode_workflow_value "$line")"
    done <<< "$val"
  fi

  # Build a random heredoc delimiter without piping /dev/urandom through tr,
  # which trips `set -o pipefail` via SIGPIPE on head.
  rand_hex="$(LC_ALL=C dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"
  if [[ -z "$rand_hex" ]]; then
    rand_hex="${RANDOM}${RANDOM}${RANDOM}"
  fi
  delim="OP_EOF_${rand_hex}"
  if [[ "${INPUT_EXPORT_ENV:-false}" == "true" ]]; then
    target="$GITHUB_ENV"
  else
    target="$GITHUB_OUTPUT"
  fi
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$val"
    printf '%s\n' "$delim"
  } >> "$target"

  managed+=("$name")
done

if [[ "${INPUT_EXPORT_ENV:-false}" == "true" && ${#managed[@]} -gt 0 ]]; then
  ( IFS=','; printf 'OP_MANAGED_VARIABLES=%s\n' "${managed[*]}" ) >> "$GITHUB_ENV"
fi
