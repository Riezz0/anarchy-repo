#!/bin/bash
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    echo "Do not run this script as root. Run as a user with sudo privileges."
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="${REPO_DIR}/x86_64"
BUILD_DIR="/tmp/update-repo-build"
AUR_URL="https://aur.archlinux.org/rpc/v5"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

UPDATED=0
SKIPPED=0
FAILED=0
CUSTOM=0

log_info()  { echo -e "${CYAN}  ➜ $*${NC}"; }
log_ok()    { echo -e "${GREEN}  ✓ $*${NC}"; }
log_warn()  { echo -e "${YELLOW}  ⚠ $*${NC}"; }
log_err()   { echo -e "${RED}  ✖ $*${NC}"; }

# Check dependencies
for cmd in curl jq vercmp repo-add; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}✖ Required command not found: $cmd${NC}"
        exit 1
    fi
done

if [ ! -d "$PKG_DIR" ]; then
    echo -e "${RED}✖ Package directory not found: $PKG_DIR${NC}"
    exit 1
fi

mkdir -p "$BUILD_DIR"

echo -e "\n${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Anarchy Repo Update Checker${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}\n"

# Get list of unique package names (strip version and arch from filename)
mapfile -t PKG_FILES < <(ls "$PKG_DIR"/*.pkg.tar.zst 2>/dev/null || true)

if [ ${#PKG_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No packages found in $PKG_DIR${NC}"
    exit 0
fi

echo -e "Found ${#PKG_FILES[@]} packages to check.\n"

for pkg_file in "${PKG_FILES[@]}"; do
    filename=$(basename "$pkg_file")

    # Extract package name from filename
    # Format: name-version-release-arch.pkg.tar.zst
    pkg_name=$(echo "$filename" | sed 's/-[0-9].*//')

    # Extract local version (everything between name and arch)
    local_ver=$(echo "$filename" | sed "s/^${pkg_name}-//" | sed 's/-[a-z_]*\.\(pkg\.tar\.zst\)$//')

    echo -e "${CYAN}Checking: ${pkg_name}${NC} (local: ${local_ver})"

    # --- Try AUR first ---
    aur_info=$(curl -sf "${AUR_URL}/info/${pkg_name}" 2>/dev/null || echo '{"resultcount":0}')
    aur_count=$(echo "$aur_info" | jq -r '.resultcount // 0')

    if [ "$aur_count" -gt 0 ]; then
        remote_ver=$(echo "$aur_info" | jq -r '.results[0].Version')
        log_info "Found in AUR (remote: ${remote_ver})"

        if vercmp "$local_ver" "$remote_ver" &>/dev/null && [ "$(vercmp "$local_ver" "$remote_ver")" -ge 0 ]; then
            log_ok "Up to date"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        log_info "Update available! Building ${pkg_name} ${remote_ver}..."
        rm -rf "${BUILD_DIR}/${pkg_name}"
        mkdir -p "${BUILD_DIR}/${pkg_name}"

        if (cd "${BUILD_DIR}/${pkg_name}" && git clone --depth 1 "https://aur.archlinux.org/${pkg_name}.git" . 2>&1); then
            if (cd "${BUILD_DIR}/${pkg_name}" && makepkg -sif --noconfirm 2>&1); then
                new_pkg=$(ls "${BUILD_DIR}/${pkg_name}"/*.pkg.tar.zst 2>/dev/null | head -1)
                if [ -n "$new_pkg" ]; then
                    rm -f "$pkg_file"
                    cp "$new_pkg" "$PKG_DIR/"
                    log_ok "Updated ${pkg_name}: ${local_ver} -> ${remote_ver}"
                    UPDATED=$((UPDATED + 1))
                else
                    log_err "Build succeeded but no package file found"
                    FAILED=$((FAILED + 1))
                fi
            else
                log_err "makepkg failed for ${pkg_name}"
                FAILED=$((FAILED + 1))
            fi
        else
            log_err "Failed to clone AUR repo for ${pkg_name}"
            FAILED=$((FAILED + 1))
        fi
        rm -rf "${BUILD_DIR}/${pkg_name}"
        continue
    fi

    # --- Try official repos ---
    pacman_ver=$(pacman -Si "$pkg_name" 2>/dev/null | grep "^Version" | awk '{print $3}' || echo "")

    if [ -n "$pacman_ver" ]; then
        log_info "Found in official repos (remote: ${pacman_ver})"

        if vercmp "$local_ver" "$pacman_ver" &>/dev/null && [ "$(vercmp "$local_ver" "$pacman_ver")" -ge 0 ]; then
            log_ok "Up to date"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        log_info "Update available! Downloading ${pkg_name} ${pacman_ver}..."
        TEMP_CACHE="${BUILD_DIR}/${pkg_name}-cache"
        mkdir -p "$TEMP_CACHE"

        if sudo pacman -Sw --noconfirm --cachedir "$TEMP_CACHE" "$pkg_name" 2>&1; then
            new_pkg=$(ls "$TEMP_CACHE"/*.pkg.tar.zst 2>/dev/null | head -1)
            if [ -n "$new_pkg" ]; then
                rm -f "$pkg_file"
                cp "$new_pkg" "$PKG_DIR/"
                log_ok "Updated ${pkg_name}: ${local_ver} -> ${pacman_ver}"
                UPDATED=$((UPDATED + 1))
            else
                log_err "Download succeeded but no package file found"
                FAILED=$((FAILED + 1))
            fi
        else
            log_err "Failed to download ${pkg_name} from official repos"
            FAILED=$((FAILED + 1))
        fi
        rm -rf "$TEMP_CACHE"
        continue
    fi

    # --- Not in AUR or official repos ---
    log_warn "Not in AUR or official repos (custom package), skipping"
    CUSTOM=$((CUSTOM + 1))
done

# Cleanup
rm -rf "$BUILD_DIR"

# Summary
echo -e "\n${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Summary${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Updated:${NC}  ${UPDATED}"
echo -e "  ${CYAN}Current:${NC}  ${SKIPPED}"
echo -e "  ${YELLOW}Custom:${NC}   ${CUSTOM}"
echo -e "  ${RED}Failed:${NC}   ${FAILED}"
echo -e "${CYAN}════════════════════════════════════════${NC}"

if [ "$UPDATED" -gt 0 ]; then
    echo -e "\n${YELLOW}Run repo-maker.sh to rebuild the database and push.${NC}"
fi
