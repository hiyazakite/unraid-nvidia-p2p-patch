#!/bin/bash
# =============================================================================
# patch-driver.sh
#
# Patches the Unraid nvidia-driver plugin package with open-gpu-kernel-modules
# (P2P-enabled kernel modules for 4090/5090).
#
# Must be run on the Unraid host (or in the unraid_kernel Docker container)
# so kernel headers are available.
#
# Usage:
#   patch-driver.sh [OPTIONS]
#
# Options:
#   --kernel-version <ver>    Override kernel version (default: uname -r)
#   --driver-version <ver>    Override driver version (e.g. 590.48.01)
#   --src-dir <path>          Path to open-gpu-kernel-modules source
#                             (if not provided, source is auto-downloaded)
#   --plugin-dir <path>       Plugin packages dir
#                             (default: /boot/config/plugins/nvidia-driver/packages)
#   --check                   List all driver versions with a P2P patch available
#                             and show whether the currently installed driver is
#                             compatible. Does not build or modify anything.
#   --dry-run                 Print what would be done, don't change anything
#   --reload                  After patching, reload the live kernel modules
#   --help                    Show this help
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
KERNEL_VERSION=""
DRIVER_VERSION=""
SRC_DIR=""
PLUGIN_PACKAGES_DIR="/boot/config/plugins/nvidia-driver/packages"
DRY_RUN=false
RELOAD=false
CHECK_ONLY=false
IN_DOCKER=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Save original args before parsing (needed for Docker re-exec)
ORIG_ARGS=("$@")

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GRN}[OK]${NC}    $*"; }
warn()  { echo -e "${YEL}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Docker Helper
# ---------------------------------------------------------------------------
ensure_docker_image() {
  local img="ich777/unraid_kernel"
  if docker image inspect "$img" >/dev/null 2>&1; then
    return 0
  fi

  info "Docker image '$img' not found locally."
  info "Building from source (https://github.com/ich777/unraid_kernel)..."

  if ! command -v git &>/dev/null; then
    die "git is required to clone the Docker repo but is not installed."
  fi

  local build_dir
  build_dir="$(mktemp -d)"
  trap 'rm -rf "$build_dir"' RETURN
  trap 'rm -rf "$build_dir"; exit 1' INT TERM

  info "Cloning repo to $build_dir ..."
  if ! git clone --depth 1 https://github.com/ich777/unraid_kernel.git "$build_dir"; then
    die "Failed to clone ich777/unraid_kernel repo."
  fi

  # Patch Dockerfile to exclude "testing" packages (fixes aaa_glibc-solibs matching multiple files)
  info "Patching Dockerfile to exclude testing packages..."
  sed -i "s/grep '\\\\.txz$'/grep '\\\\.txz$' | grep -v 'testing'/" "$build_dir/Dockerfile"

  # Patch installscript.sh to exclude "pasture" packages (fixes cmake matching multiple files)
  info "Patching installscript.sh to exclude pasture packages..."
  sed -i 's#grep -v "/patches/"#grep -v "/patches/" | grep -v "/pasture/"#' "$build_dir/installscript.sh"

  # Patch installscript.sh to use stock jq from Slackware repo (Alien Bob's link is broken/old)
  info "Patching installscript.sh to use stock jq..."
  # Add jq and oniguruma (libonig dependency) to main package list
  sed -i 's/nghttp3/nghttp3\n  jq\n  oniguruma/' "$build_dir/installscript.sh"
  # Remove the broken manual install block
  sed -i '/# install jq/,/installpkg .*jq-/d' "$build_dir/installscript.sh"

  # Patch start scripts to run passed command instead of sleeping forever
  info "Patching container start scripts to execute arguments..."
  # start-container.sh: Replace final 'sleep infinity' with 'exit 0' so it returns control
  sed -i '$s/sleep infinity/exit 0/' "$build_dir/docker-scripts/start-container.sh"
  # start.sh: Run start-container.sh in foreground, remove loop, exec "$@"
  sed -i 's|/opt/scripts/start-container.sh &|/opt/scripts/start-container.sh|' "$build_dir/docker-scripts/start.sh"
  sed -i '/killpid/d' "$build_dir/docker-scripts/start.sh"
  sed -i '/while true/,/done/d' "$build_dir/docker-scripts/start.sh"
  echo 'exec "$@"' >> "$build_dir/docker-scripts/start.sh"

  info "Building Docker image..."
  if ! docker build -t "$img" "$build_dir"; then
    die "Failed to build Docker image."
  fi

  ok "Docker image '$img' built successfully."
}

# ---------------------------------------------------------------------------
# Compatibility check
# ---------------------------------------------------------------------------
# The aikitoria/open-gpu-kernel-modules repo publishes P2P patches as *branches*
# named "<version>-p2p" (e.g. "590.48.01-p2p"). There are no GitHub releases.
# We query the branches API and filter for -p2p branches to build the list.
# ---------------------------------------------------------------------------
check_compatibility() {
  local installed_version="$1"
  local repo="aikitoria/open-gpu-kernel-modules"
  # GitHub branches API — paginated; 100 is the maximum per page.
  local api_url="https://api.github.com/repos/${repo}/branches?per_page=100"

  info "Fetching P2P-patched branches from github.com/${repo} ..."

  local raw
  raw="$(wget -qO- -T 15 "$api_url")" || die "Failed to reach GitHub API. Check your internet connection."

  if [[ -z "$raw" ]]; then
    die "Empty response from GitHub API."
  fi

  if echo "$raw" | grep -q '"rate limit"'; then
    die "GitHub API rate limit exceeded. Try again later."
  fi

  # Extract branch names that end with "-p2p", strip the suffix to get driver version.
  local available_versions
  available_versions="$(
    echo "$raw" \
      | grep '"name"' \
      | sed 's/.*"name": *"//;s/".*//' \
      | grep -- '-p2p$' \
      | sed 's/-p2p$//' \
      | sort -V
  )"

  if [[ -z "$available_versions" ]]; then
    die "No -p2p branches found in ${repo}. The repo structure may have changed."
  fi

  echo
  echo -e "${CYN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYN}║    P2P-patched driver versions (aikitoria/open-gpu-kernel)   ║${NC}"
  echo -e "${CYN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo

  local compatible=false
  local latest_compatible=""
  while IFS= read -r ver; do
    [[ -z "$ver" ]] && continue
    if [[ "$ver" == "$installed_version" ]]; then
      echo -e "  ${GRN}✔  $ver${NC}  ← your installed driver (COMPATIBLE)"
      compatible=true
    else
      echo -e "     $ver"
    fi
    latest_compatible="$ver"   # last after sort -V = newest
  done <<< "$available_versions"

  echo
  echo -e "  Installed driver : ${YEL}${installed_version}${NC}"
  if [[ "$compatible" == true ]]; then
    echo -e "  P2P status       : ${GRN}COMPATIBLE ✔${NC}"
    echo -e "  Run without --check to apply the patch."
  else
    echo -e "  P2P status       : ${RED}NOT COMPATIBLE ✘${NC}"
    echo
    echo -e "  Your driver (${YEL}${installed_version}${NC}) has no P2P branch in the aikitoria fork."
    echo -e "  Newest patched version: ${GRN}${latest_compatible}${NC}"
    echo
    echo -e "  Options:"
    echo -e "  1) Change your Unraid driver to ${GRN}${latest_compatible}${NC}"
    echo -e "     Plugins → nvidia-driver → Choose version in the Unraid WebUI"
    echo -e "  2) Re-run this script after switching."
    echo
    echo -e "  Branch list: ${CYN}https://github.com/${repo}/branches${NC}"
  fi
  echo
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
    --driver-version) DRIVER_VERSION="$2"; shift 2 ;;
    --src-dir)        SRC_DIR="$2";        shift 2 ;;
    --plugin-dir)     PLUGIN_PACKAGES_DIR="$2"; shift 2 ;;
    --check)          CHECK_ONLY=true;     shift   ;;
    --dry-run)        DRY_RUN=true;        shift   ;;
    --reload)         RELOAD=true;         shift   ;;
    --in-docker)      IN_DOCKER=true;      shift   ;; # internal: already inside container
    --help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Step 1 – Detect kernel version
# ---------------------------------------------------------------------------
if [[ -z "$KERNEL_VERSION" ]]; then
  KERNEL_VERSION="$(uname -r)"
fi
info "Kernel version : $KERNEL_VERSION"

KERNEL_SHORT="${KERNEL_VERSION%%-*}"   # e.g. 6.12.54
PKG_DIR="${PLUGIN_PACKAGES_DIR}/${KERNEL_SHORT}"

if [[ ! -d "$PKG_DIR" ]]; then
  die "Package directory not found: $PKG_DIR"
fi

# ---------------------------------------------------------------------------
# Step 2 – Detect driver version from the installed package filename
#
# Filename format: nvidia-<driver_ver>-<kernel_ver>-1.txz
# ---------------------------------------------------------------------------
PACKAGE_FILE=""
for f in "${PKG_DIR}"/nvidia-*.txz; do
  [[ -e "$f" ]] || die "No nvidia-*.txz package found in: $PKG_DIR"
  PACKAGE_FILE="$f"
  break
done

PACKAGE_BASENAME="$(basename "$PACKAGE_FILE")"   # e.g. nvidia-580.82.09-6.12.24-Unraid-1.txz
# Extract the nvidia driver version: the first X.Y.Z pattern in the filename.
# This is robust to any kernel suffix format (plain, -Unraid, etc.).
DETECTED_DRIVER_VERSION="$(echo "$PACKAGE_BASENAME" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

if [[ -z "$DRIVER_VERSION" ]]; then
  DRIVER_VERSION="$DETECTED_DRIVER_VERSION"
fi

info "Driver version : $DRIVER_VERSION"
info "Package file   : $PACKAGE_FILE"

# ---------------------------------------------------------------------------
# --check: show compatibility and exit without modifying anything
# ---------------------------------------------------------------------------
if [[ "$CHECK_ONLY" == true ]]; then
  check_compatibility "$DRIVER_VERSION"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 3 – Obtain the open-gpu-kernel-modules source
#
# If --src-dir is supplied, use that.  Otherwise check for a sibling directory
# named "open-gpu-kernel-modules" and verify its version, or download the
# matching release tarball from GitHub.
# ---------------------------------------------------------------------------
GITHUB_REPO="aikitoria/open-gpu-kernel-modules"

resolve_src_dir() {
  local candidate="$1"
  if [[ ! -d "$candidate" ]]; then return 1; fi
  local src_version
  src_version="$(grep -m1 'NVIDIA_VERSION' "${candidate}/version.mk" 2>/dev/null | awk '{print $3}')" || true
  if [[ "$src_version" == "$DRIVER_VERSION" ]]; then
    ok "Found matching source ($src_version) at: $candidate"
    SRC_DIR="$candidate"
    return 0
  else
    warn "Source at $candidate has version $src_version (need $DRIVER_VERSION)"
    return 1
  fi
}

if [[ -n "$SRC_DIR" ]]; then
  # User-supplied path – just validate.
  if [[ ! -d "$SRC_DIR" ]]; then
    die "--src-dir not found: $SRC_DIR"
  fi
  src_version="$(grep -m1 'NVIDIA_VERSION' "${SRC_DIR}/version.mk" 2>/dev/null | awk '{print $3}')" || true
  if [[ "$src_version" != "$DRIVER_VERSION" ]]; then
    warn "Source version ($src_version) does not match driver version ($DRIVER_VERSION)."
    warn "Proceeding anyway – make sure your source is correct."
  fi
else
  # Try the sibling directory first.
  SIBLING_DIR="${SCRIPT_DIR}/open-gpu-kernel-modules"
  if ! resolve_src_dir "$SIBLING_DIR"; then
    # Download the release tarball for the exact driver version.
    info "Downloading open-gpu-kernel-modules $DRIVER_VERSION from GitHub..."
    DOWNLOAD_DIR="${SCRIPT_DIR}/open-gpu-kernel-modules-${DRIVER_VERSION}"
    TARBALL="${SCRIPT_DIR}/open-gpu-kernel-modules-${DRIVER_VERSION}.tar.gz"

    if [[ "$DRY_RUN" == false ]]; then
      # aikitoria publishes P2P patches as *branches* named "<version>-p2p".
      # GitHub lets you download a branch archive at /archive/refs/heads/<branch>.tar.gz
      AIKITORIA_BRANCH="${DRIVER_VERSION}-p2p"
      NVIDIA_TAG="${DRIVER_VERSION}"

      if wget -q --spider "https://github.com/${GITHUB_REPO}/archive/refs/heads/${AIKITORIA_BRANCH}.tar.gz" 2>/dev/null; then
        DL_URL="https://github.com/${GITHUB_REPO}/archive/refs/heads/${AIKITORIA_BRANCH}.tar.gz"
      elif wget -q --spider "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${NVIDIA_TAG}.tar.gz" 2>/dev/null; then
        warn "aikitoria branch '${AIKITORIA_BRANCH}' not found – falling back to NVIDIA upstream (no P2P patch!)"
        warn "Run --check to see which driver versions are supported."
        DL_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${NVIDIA_TAG}.tar.gz"
      else
        die "Cannot find open-gpu-kernel-modules for driver $DRIVER_VERSION.
  Run --check to see which driver versions have a P2P patch available.
  Or supply the source directly: --src-dir /path/to/open-gpu-kernel-modules"
      fi

      mkdir -p "$DOWNLOAD_DIR"
      wget -q --show-progress --progress=bar:force:noscroll \
        -O "$TARBALL" "$DL_URL"
      tar -xf "$TARBALL" -C "$DOWNLOAD_DIR" --strip-components=1
      rm -f "$TARBALL"
      SRC_DIR="$DOWNLOAD_DIR"
      ok "Source downloaded to: $SRC_DIR"
    else
      info "[DRY-RUN] Would download $DRIVER_VERSION source from GitHub"
      SRC_DIR="${SIBLING_DIR}_DRYRUN"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 4 – Check build tools, then build the patched kernel modules
# ---------------------------------------------------------------------------

# Unraid does not ship build tools by default. Verify before attempting the build.
MISSING_TOOLS=()
for tool in make gcc cc; do
  command -v "$tool" &>/dev/null || MISSING_TOOLS+=("$tool")
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  if [[ "$IN_DOCKER" == true ]]; then
    # Already inside the container — tools should be there, something is wrong.
    die "Build tools still missing inside Docker (${MISSING_TOOLS[*]}). The container image may be outdated."
  fi

  warn "Build tools not found: ${MISSING_TOOLS[*]}"

  if ! command -v docker &>/dev/null; then
    error "Docker is also not available."
    echo
    echo -e "  Install Docker on Unraid (Community Apps → Docker), then re-run."
    echo -e "  Or manually run inside the build container:"
    echo -e "  ${YEL}docker run --rm -it \\"
    echo -e "    -v \"${SCRIPT_DIR}:/build\" \\"
    echo -e "    -v /boot:/boot \\"
    echo -e "    ich777/unraid_kernel \\"
    echo -e "    bash /build/$(basename "$0") ${ORIG_ARGS[*]}${NC}"
    exit 1
  fi

  ensure_docker_image

  info "Re-launching inside ich777/unraid_kernel container..."
  # Use --init to forward signals (Ctrl+C) correctly to the container process
  docker run --rm -it --init \
    -v "${SCRIPT_DIR}:/build" \
    -v /boot:/boot \
    ich777/unraid_kernel \
    bash "/build/$(basename "$0")" "${ORIG_ARGS[@]}" --in-docker
  
  exit $?
fi

BUILD_LOG="${SCRIPT_DIR}/patch-build.log"
info "Building kernel modules (log: $BUILD_LOG)..."

if [[ "$DRY_RUN" == false ]]; then
  pushd "$SRC_DIR" > /dev/null
  make modules -j"$(nproc)" KERNEL_UNAME="${KERNEL_VERSION}" 2>&1 | tee "$BUILD_LOG"
  popd > /dev/null
  ok "Build complete."
else
  info "[DRY-RUN] Would run: make modules -j\$(nproc) KERNEL_UNAME=${KERNEL_VERSION}"
  info "  in directory: $SRC_DIR"
fi

# ---------------------------------------------------------------------------
# Step 5 – Collect built .ko files
# ---------------------------------------------------------------------------
# The built modules end up in kernel-open/<subdir>/*.ko
declare -A BUILT_KO  # map: basename → full path
if [[ "$DRY_RUN" == false ]]; then
  while IFS= read -r -d '' ko; do
    BUILT_KO["$(basename "$ko")"]="$ko"
  done < <(find "${SRC_DIR}/kernel-open" -name "*.ko" -print0 2>/dev/null)

  if [[ ${#BUILT_KO[@]} -eq 0 ]]; then
    die "No .ko files found after build. Check $BUILD_LOG"
  fi
  info "Built modules:"
  for name in "${!BUILT_KO[@]}"; do
    echo "  ${BUILT_KO[$name]}"
  done
else
  info "[DRY-RUN] Would collect .ko files from ${SRC_DIR}/kernel-open/"
fi

# ---------------------------------------------------------------------------
# Step 6 – Extract the driver package and swap modules
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

info "Extracting package to: $WORK_DIR"

if [[ "$DRY_RUN" == false ]]; then
  tar -xf "$PACKAGE_FILE" -C "$WORK_DIR"

  # Kernel modules are at lib/modules/<kernel>/kernel/drivers/video/*.ko
  KO_INSTALL_DIR="${WORK_DIR}/lib/modules/${KERNEL_VERSION}/kernel/drivers/video"

  if [[ ! -d "$KO_INSTALL_DIR" ]]; then
    die "Expected module dir not found in package: $KO_INSTALL_DIR"
  fi

  info "Module install dir: $KO_INSTALL_DIR"

  REPLACED=0
  while IFS= read -r -d '' existing_ko; do
    ko_name="$(basename "$existing_ko")"
    if [[ -n "${BUILT_KO[$ko_name]+x}" ]]; then
      info "  Replacing: $ko_name"
      cp -f "${BUILT_KO[$ko_name]}" "$existing_ko"
      REPLACED=$((REPLACED + 1))
    else
      warn "  No built replacement for: $ko_name (keeping original)"
    fi
  done < <(find "$KO_INSTALL_DIR" -name "*.ko" -print0)

  ok "Replaced $REPLACED kernel module(s)."
else
  info "[DRY-RUN] Would extract $PACKAGE_FILE and replace .ko files in:"
  info "  lib/modules/${KERNEL_VERSION}/kernel/drivers/video/"
fi

# ---------------------------------------------------------------------------
# Step 7 – Repackage the .txz
# ---------------------------------------------------------------------------
NEW_PACKAGE="${PACKAGE_FILE%.txz}.patched.txz"

info "Repackaging -> $(basename "$NEW_PACKAGE")"

if [[ "$DRY_RUN" == false ]]; then
  # Use makepkg if available (standard Slackware/Unraid tool).
  if command -v makepkg &>/dev/null; then
    pushd "$WORK_DIR" > /dev/null
    makepkg -l n -c n "$NEW_PACKAGE"
    popd > /dev/null
  else
    # Fallback: create a plain .txz (tar + xz).
    # This may lack Slackware package metadata but is usually sufficient.
    warn "makepkg not found – creating plain tar.xz archive."
    pushd "$WORK_DIR" > /dev/null
    tar -cJf "$NEW_PACKAGE" .
    popd > /dev/null
  fi

  # Replace original package.
  mv -f "$NEW_PACKAGE" "$PACKAGE_FILE"

  # Update md5.
  MD5_FILE="${PACKAGE_FILE}.md5"
  md5sum "$PACKAGE_FILE" | awk '{print $1}' > "$MD5_FILE"
  ok "Package updated: $PACKAGE_FILE"
  ok "MD5 updated   : $MD5_FILE"
else
  info "[DRY-RUN] Would repackage to: $PACKAGE_FILE"
  info "[DRY-RUN] Would update md5  : ${PACKAGE_FILE}.md5"
fi

# ---------------------------------------------------------------------------
# Step 8 – Optionally reload live kernel modules
# ---------------------------------------------------------------------------
if [[ "$RELOAD" == true ]]; then
  if [[ "$DRY_RUN" == false ]]; then
    info "Reloading kernel modules..."
    rmmod nvidia_drm  2>/dev/null || true
    rmmod nvidia_modeset 2>/dev/null || true
    rmmod nvidia_uvm 2>/dev/null || true
    rmmod nvidia 2>/dev/null || true
    installpkg "$PACKAGE_FILE" > /dev/null
    depmod --all > /dev/null
    modprobe nvidia > /dev/null
    ok "Modules reloaded."
  else
    info "[DRY-RUN] Would reload: rmmod + installpkg + depmod + modprobe nvidia"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
ok "=================================================================="
ok "  Patching complete!"
ok "  Driver: $DRIVER_VERSION  |  Kernel: $KERNEL_VERSION"
ok "  Package: $PACKAGE_FILE"
if [[ "$RELOAD" == false ]]; then
  warn "  Reboot or use --reload to activate the patched modules."
fi
ok "=================================================================="
