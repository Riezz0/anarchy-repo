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
MUTED='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# Result tracking
UPDATED_LIST=()
CURRENT_LIST=()
CUSTOM_LIST=()
FAILED_LIST=()

log_info()  { echo -e "${CYAN}  ➜ $*${NC}"; }
log_ok()    { echo -e "${GREEN}  ✓ $*${NC}"; }
log_warn()  { echo -e "${YELLOW}  ⚠ $*${NC}"; }
log_err()   { echo -e "${RED}  ✖ $*${NC}"; }

# Check dependencies
for cmd in curl jq vercmp repo-add pacman; do
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

echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Anarchy Repo Update Checker${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}\n"

mapfile -t PKG_FILES < <(ls "$PKG_DIR"/*.pkg.tar.zst 2>/dev/null || true)

if [ ${#PKG_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No packages found in $PKG_DIR${NC}"
    exit 0
fi

echo -e "Found ${#PKG_FILES[@]} packages to check.\n"

cleanup_build_deps() {
    local build_dir="$1"
    local keep_pkg="$2"
    # Find packages that were installed during makepkg and remove them
    if [ -f "${build_dir}/.installed_before" ]; then
        current_pkgs=$(mktemp)
        pacman -Qq 2>/dev/null > "$current_pkgs" || true
        comm -13 <(sort "${build_dir}/.installed_before") <(sort "$current_pkgs") > "${build_dir}/.new_deps" || true
        # Exclude the package we just built from removal
        if [ -n "$keep_pkg" ]; then
            grep -v "^${keep_pkg}$" "${build_dir}/.new_deps" > "${build_dir}/.new_deps.filtered" || true
            mv "${build_dir}/.new_deps.filtered" "${build_dir}/.new_deps"
        fi
        if [ -s "${build_dir}/.new_deps" ]; then
            log_info "Cleaning up build dependencies..."
            sudo pacman -Rns --noconfirm $(cat "${build_dir}/.new_deps") 2>/dev/null || true
        fi
        rm -f "$current_pkgs" "${build_dir}/.installed_before" "${build_dir}/.new_deps"
    fi
}

for pkg_file in "${PKG_FILES[@]}"; do
    filename=$(basename "$pkg_file")

    # Extract package name from filename
    pkg_name=$(echo "$filename" | sed 's/-[0-9].*//')

    # Extract local version
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
            CURRENT_LIST+=("${pkg_name} ${local_ver}")
            continue
        fi

        log_info "Update available! Building ${pkg_name} ${remote_ver}..."
        rm -rf "${BUILD_DIR}/${pkg_name}"

        build_ok=true
        if git clone --depth 1 "https://aur.archlinux.org/${pkg_name}.git" "${BUILD_DIR}/${pkg_name}" 2>&1; then
            # Record installed packages before build
            pacman -Qq 2>/dev/null > "${BUILD_DIR}/${pkg_name}/.installed_before" || true

            # Remove check() function to skip tests
            if [ -f "${BUILD_DIR}/${pkg_name}/PKGBUILD" ]; then
                sed -i '/^check()/,/^}/d' "${BUILD_DIR}/${pkg_name}/PKGBUILD"
            fi

            if (cd "${BUILD_DIR}/${pkg_name}" && makepkg -sif --noconfirm 2>&1); then
                new_pkg=$(ls "${BUILD_DIR}/${pkg_name}"/*.pkg.tar.zst 2>/dev/null | head -1)
                if [ -n "$new_pkg" ]; then
                    rm -f "$pkg_file"
                    cp "$new_pkg" "$PKG_DIR/"
                    log_ok "Updated ${pkg_name}: ${local_ver} -> ${remote_ver}"
                    UPDATED_LIST+=("${pkg_name} ${local_ver} -> ${remote_ver}")
                else
                    log_err "Build succeeded but no package file found"
                    FAILED_LIST+=("${pkg_name} (build succeeded but no package file found)")
                    build_ok=false
                fi
            else
                log_err "makepkg failed for ${pkg_name}"
                FAILED_LIST+=("${pkg_name} (makepkg failed)")
                build_ok=false
            fi
        else
            log_err "Failed to clone AUR repo for ${pkg_name}"
            FAILED_LIST+=("${pkg_name} (failed to clone AUR repo)")
            build_ok=false
        fi

        # Clean up build dependencies
        cleanup_build_deps "${BUILD_DIR}/${pkg_name}" "$pkg_name"
        rm -rf "${BUILD_DIR}/${pkg_name}"
        continue
    fi

    # --- Try official repos ---
    pacman_ver=$(pacman -Si "$pkg_name" 2>/dev/null | grep "^Version" | awk '{print $3}' || echo "")

    if [ -n "$pacman_ver" ]; then
        log_info "Found in official repos (remote: ${pacman_ver})"

        if vercmp "$local_ver" "$pacman_ver" &>/dev/null && [ "$(vercmp "$local_ver" "$pacman_ver")" -ge 0 ]; then
            log_ok "Up to date"
            CURRENT_LIST+=("${pkg_name} ${local_ver}")
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
                UPDATED_LIST+=("${pkg_name} ${local_ver} -> ${pacman_ver}")
            else
                log_err "Download succeeded but no package file found"
                FAILED_LIST+=("${pkg_name} (download succeeded but no package file found)")
            fi
        else
            log_err "Failed to download ${pkg_name} from official repos"
            FAILED_LIST+=("${pkg_name} (failed to download from official repos)")
        fi
        rm -rf "$TEMP_CACHE"
        continue
    fi

    # --- Not in AUR or official repos ---
    log_warn "Not in AUR or official repos (custom package), skipping"
    CUSTOM_LIST+=("${pkg_name}")
done

# Cleanup
rm -rf "$BUILD_DIR"

# Summary
echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Summary${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"

echo -e "\n  ${GREEN}${BOLD}Updated (${#UPDATED_LIST[@]}):${NC}"
if [ ${#UPDATED_LIST[@]} -gt 0 ]; then
    for item in "${UPDATED_LIST[@]}"; do
        echo -e "    ${GREEN}✓${NC} $item"
    done
else
    echo -e "    ${MUTED}(none)${NC}"
fi

echo -e "\n  ${CYAN}${BOLD}Already up to date (${#CURRENT_LIST[@]}):${NC}"
if [ ${#CURRENT_LIST[@]} -gt 0 ]; then
    for item in "${CURRENT_LIST[@]}"; do
        echo -e "    ${CYAN}✓${NC} $item"
    done
else
    echo -e "    ${MUTED}(none)${NC}"
fi

echo -e "\n  ${YELLOW}${BOLD}Skipped - custom packages (${#CUSTOM_LIST[@]}):${NC}"
if [ ${#CUSTOM_LIST[@]} -gt 0 ]; then
    for item in "${CUSTOM_LIST[@]}"; do
        echo -e "    ${YELLOW}⚠${NC} $item"
    done
else
    echo -e "    ${MUTED}(none)${NC}"
fi

echo -e "\n  ${RED}${BOLD}Failed (${#FAILED_LIST[@]}):${NC}"
if [ ${#FAILED_LIST[@]} -gt 0 ]; then
    for item in "${FAILED_LIST[@]}"; do
        echo -e "    ${RED}✖${NC} $item"
    done
else
    echo -e "    ${MUTED}(none)${NC}"
fi

echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"

if [ ${#UPDATED_LIST[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Run repo-maker.sh to rebuild the database and push.${NC}"
fi
