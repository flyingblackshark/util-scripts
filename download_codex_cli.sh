#!/usr/bin/env bash
set -euo pipefail

# 从 GitHub 下载 openai/codex 的最新 Codex CLI 到当前目录。
# 产物：./codex（Linux/macOS）或 ./codex.exe（Windows）
#
# 可选环境变量：
#   CODEX_REPO=openai/codex            # 默认仓库
#   CODEX_LINUX_LIBC=musl|gnu          # Linux 目标 libc（默认 musl，更通用）
#   CODEX_FORMAT=tar.gz|zst|zip|dmg|raw # 下载格式（不同系统支持不同）
#   CODEX_KEEP_ARCHIVE=1               # 保留下载的压缩包（默认删除）
#   CODEX_AUTO_INSTALL=1               # Ubuntu 下自动 apt 安装缺失依赖（默认开启）
#   GITHUB_TOKEN=...                   # 可选，用于避免 GitHub API 限流

REPO="${CODEX_REPO:-openai/codex}"
LINUX_LIBC="${CODEX_LINUX_LIBC:-musl}"
FORMAT="${CODEX_FORMAT:-}"
KEEP_ARCHIVE="${CODEX_KEEP_ARCHIVE:-0}"
AUTO_INSTALL="${CODEX_AUTO_INSTALL:-1}"

err() { echo "ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

ubuntu_like=0
if [[ -r /etc/os-release ]]; then
  os_id="$(. /etc/os-release && echo "${ID:-}")"
  os_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
  if [[ "$os_id" == "ubuntu" ]]; then
    ubuntu_like=1
  elif [[ "$os_like" == *ubuntu* || "$os_like" == *debian* ]]; then
    ubuntu_like=1
  fi
fi

apt_updated=0
as_root() {
  if [[ "${EUID:-0}" -eq 0 ]]; then
    "$@"
    return
  fi
  command -v sudo >/dev/null 2>&1 || die "需要 sudo/root 权限来安装依赖"
  sudo "$@"
}

apt_install() {
  [[ "$AUTO_INSTALL" == "1" ]] || return 1
  [[ "$ubuntu_like" -eq 1 ]] || return 1
  command -v apt-get >/dev/null 2>&1 || return 1

  if [[ "$apt_updated" -eq 0 ]]; then
    echo "安装依赖: apt-get update"
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update
    apt_updated=1
  fi

  echo "安装依赖: apt-get install -y $*"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

ensure_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  case "$cmd" in
    python3) apt_install python3 ;;
    curl) apt_install ca-certificates curl ;;
    wget) apt_install ca-certificates wget ;;
    tar) apt_install tar ;;
    unzip) apt_install unzip ;;
    zstd) apt_install zstd ;;
    mktemp|uname) apt_install coreutils ;;
    *)
      die "缺少依赖: $cmd"
      ;;
  esac

  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖: $cmd"
}

download() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "$out" "$url"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
    return 0
  fi

  ensure_cmd curl
  curl -fL --retry 3 --connect-timeout 15 -o "$out" "$url"
}

ensure_cmd uname
ensure_cmd python3
ensure_cmd mktemp

uname_s="$(uname -s)"
uname_m="$(uname -m)"

case "$uname_s" in
  Linux) platform_os="linux" ;;
  Darwin) platform_os="darwin" ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT) platform_os="windows" ;;
  *) die "不支持的系统: $uname_s" ;;
esac

case "$uname_m" in
  x86_64|amd64) platform_arch="x86_64" ;;
  aarch64|arm64) platform_arch="aarch64" ;;
  *) die "不支持的架构: $uname_m" ;;
esac

case "$platform_os" in
  linux) target="${platform_arch}-unknown-linux-${LINUX_LIBC}" ;;
  darwin) target="${platform_arch}-apple-darwin" ;;
  windows) target="${platform_arch}-pc-windows-msvc" ;;
esac

candidates=()
if [[ "$platform_os" == "windows" ]]; then
  preferred="${FORMAT:-zip}"
  case "$preferred" in
    zip) candidates+=( "codex-${target}.exe.zip" ) ;;
    tar.gz) candidates+=( "codex-${target}.exe.tar.gz" ) ;;
    zst) candidates+=( "codex-${target}.exe.zst" ) ;;
    *) die "Windows 下 CODEX_FORMAT 仅支持 zip/tar.gz/zst" ;;
  esac
  candidates+=( "codex-${target}.exe.zip" "codex-${target}.exe.tar.gz" "codex-${target}.exe.zst" )
  out_bin="./codex.exe"
  raw_name="codex-${target}.exe"
else
  preferred="${FORMAT:-tar.gz}"
  case "$preferred" in
    tar.gz) candidates+=( "codex-${target}.tar.gz" ) ;;
    zst) candidates+=( "codex-${target}.zst" ) ;;
    dmg) candidates+=( "codex-${target}.dmg" ) ;;
    raw) candidates+=( "codex-${target}" ) ;;
    *) die "mac/linux 下 CODEX_FORMAT 仅支持 tar.gz/zst/dmg/raw" ;;
  esac
  candidates+=( "codex-${target}.tar.gz" "codex-${target}.zst" "codex-${target}.dmg" "codex-${target}" )
  out_bin="./codex"
  raw_name="codex-${target}"
fi

# bash3 兼容的去重（保持顺序）
uniq_candidates=()
for name in "${candidates[@]}"; do
  skip=0
  for seen in "${uniq_candidates[@]}"; do
    [[ "$name" == "$seen" ]] && { skip=1; break; }
  done
  [[ "$skip" -eq 0 ]] && uniq_candidates+=( "$name" )
done

export REPO
export CANDIDATES="$(printf '%s\n' "${uniq_candidates[@]}")"
export TARGET_PREFIX="codex-${target}"

read -r tag asset url < <(
  python3 - <<'PY'
import json, os, sys, urllib.request

repo = os.environ["REPO"]
candidates = os.environ["CANDIDATES"].splitlines()
prefix = os.environ.get("TARGET_PREFIX", "")
token = os.environ.get("GITHUB_TOKEN")

headers = {"Accept": "application/vnd.github+json", "User-Agent": "codex-cli-downloader"}
if token:
    headers["Authorization"] = f"Bearer {token}"

req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest", headers=headers)
with urllib.request.urlopen(req) as r:
    data = json.load(r)

assets = {a["name"]: a["browser_download_url"] for a in data.get("assets", [])}
tag = data.get("tag_name", "")

for name in candidates:
    u = assets.get(name)
    if u:
        print(f"{tag}\t{name}\t{u}")
        sys.exit(0)

matches = [n for n in assets.keys() if prefix and n.startswith(prefix) and "sigstore" not in n]

def score(n: str) -> tuple:
    if n.endswith(".tar.gz"):
        return (0, len(n))
    if n.endswith(".zip"):
        return (1, len(n))
    if n.endswith(".zst"):
        return (2, len(n))
    if n.endswith(".dmg"):
        return (3, len(n))
    return (4, len(n))

matches.sort(key=score)
if matches:
    name = matches[0]
    print(f"{tag}\t{name}\t{assets[name]}")
    sys.exit(0)

hint = [n for n in assets.keys() if n.startswith("codex-")]
hint.sort()
sys.stderr.write("找不到匹配的 release 资产。可用的相关资产：\n")
for n in hint[:80]:
    sys.stderr.write(f"  - {n}\n")
sys.exit(1)
PY
)

[[ -n "${asset:-}" && -n "${url:-}" ]] || die "解析 GitHub release 信息失败"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "下载: $REPO@$tag -> $asset"
download "$url" "$tmp"
mv -f "$tmp" "./$asset"
trap - EXIT

if [[ "$asset" == *.dmg ]]; then
  echo "已下载 DMG: ./$asset"
  exit 0
fi

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

if [[ "$asset" == *.tar.gz ]]; then
  if command -v tar >/dev/null 2>&1; then
    tar -xzf "./$asset" -C "$workdir"
  else
    python3 - <<PY
import tarfile
tarfile.open("./$asset", "r:gz").extractall("$workdir")
PY
  fi
elif [[ "$asset" == *.zip ]]; then
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "./$asset" -d "$workdir"
  else
    python3 - <<PY
import zipfile
with zipfile.ZipFile("./$asset") as z:
    z.extractall("$workdir")
PY
  fi
elif [[ "$asset" == *.zst ]]; then
  ensure_cmd zstd
  zstd -d -q -c "./$asset" > "$workdir/$raw_name"
else
  cp -f "./$asset" "$workdir/$raw_name" || true
fi

bin_path=""
if [[ -f "$workdir/$raw_name" ]]; then
  bin_path="$workdir/$raw_name"
else
  bin_path="$(
    python3 - <<PY
import os
work = "$workdir"
paths = []
for root, dirs, files in os.walk(work):
    for f in files:
        if f.startswith("codex-") and "sigstore" not in f and not f.endswith(".sigstore"):
            paths.append(os.path.join(root, f))
paths.sort(key=len)
print(paths[0] if paths else "")
PY
  )"
fi

[[ -n "$bin_path" && -f "$bin_path" ]] || die "解压后未找到 codex 可执行文件"

mv -f "$bin_path" "$out_bin"
chmod +x "$out_bin" 2>/dev/null || true

if [[ "$KEEP_ARCHIVE" != "1" ]]; then
  rm -f "./$asset" || true
fi

echo "完成: $out_bin"
