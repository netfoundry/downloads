#!/usr/bin/env bash

###############################################################################
# NetFoundry Linux Package Installer
#
# This script configures NetFoundry package repositories (public or private)
# and optionally installs specified packages from those repositories.
# You can also run a post-install executable after package installation.
#
# Author: NetFoundry
# License: All Rights Reserved
# Usage: ./linux-install.bash [OPTIONS] [PACKAGE...]
# Requirements: curl/wget, gpg, apt/dnf/yum
# Version: 2.2.0
###############################################################################

set -euo pipefail

# === Logging Setup ===
LOG_FILE="/var/log/netfoundry-installer.log"
if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
  LOG_FILE="$HOME/netfoundry-installer.log"
fi

log_info() {
  echo "[INFO] $*"
}
log_error() {
  echo "[ERROR] $*" >&2
}

# Initialize log file if possible
if touch "$LOG_FILE" 2>/dev/null; then
  # Redirect all output (stdout & stderr) to tee for console + log file
  exec > >(tee -a "$LOG_FILE") 2>&1
  log_info "===== [START] $(date) - NetFoundry Package Installer ====="
else
  log_info "Note: Cannot write to log file, continuing without logging"
fi

# === Configuration ===
# Repository configuration variables
NF_REPO_HOST="netfoundry.jfrog.io"

PRIVATE_REPO="false"
REPO_USERNAME=""
REPO_PASSWORD=""
POST_EXEC=""
TEST_REPO="false"

checkSum() {
    for CMD in sha256sum md5sum; do
        if command -v "$CMD" &>/dev/null; then
            local SUMCMD="$CMD"
            break
        fi
    done
    if [ -z "${SUMCMD:-}" ]; then
        log_error "No checksum command found. Tried 'sha256sum', 'md5sum'."
        log_error "Please install coreutils or similar package containing checksum utilities."
        exit 1
    fi
    "$SUMCMD" | awk '{print $1}'
}

configureRedHatRepo(){
    log_info "Setting up NetFoundry repository for Red Hat family..."

    local PACKAGER=""
    for CMD in dnf yum; do
        if command -v "$CMD" &>/dev/null; then
            PACKAGER="$CMD"
            log_info "Found package manager: $PACKAGER"
            break
        fi
    done
    if [ -z "$PACKAGER" ]; then
        log_error "No Red Hat package manager found. Tried 'dnf', 'yum'."
        log_error "Please install dnf or yum package manager."
        exit 1
    fi

    if [[ "$PRIVATE_REPO" == "true" ]]; then
        BASE_URL=https://${NF_REPO_HOST}/artifactory/${NFPAX_RPM}
    else
        BASE_URL=https://${NF_REPO_HOST}/artifactory/${NFPAX_RPM}/redhat/\$basearch
    fi

    local REPOSRC="[NetFoundryRelease]
name=NetFoundry Release
baseurl=${BASE_URL}
enabled=1
gpgcheck=0
gpgkey=https://${NF_REPO_HOST}/artifactory/api/security/keypair/public/repositories/${NFPAX_RPM}
repo_gpgcheck=1"

    local REPOFILE="/etc/yum.repos.d/netfoundry-release.repo"
    if [ -s "$REPOFILE" ]; then
        log_info "Existing repository file found, checking for updates..."
        local EXISTINGSUM
        local REPOSUM
        EXISTINGSUM=$(checkSum < "$REPOFILE")
        REPOSUM=$(checkSum <<< "$REPOSRC")
        if [ "$EXISTINGSUM" != "$REPOSUM" ]; then
            local BACKUP_FILE="${REPOFILE}.$(date -Iseconds)"
            mv "$REPOFILE" "$BACKUP_FILE"
            log_info "Backed up existing repository file to: $BACKUP_FILE"
            echo "$REPOSRC" > "$REPOFILE"
            log_info "Updated NetFoundry repository configuration"
        else
            log_info "NetFoundry repository configuration is up to date"
        fi
    else
        log_info "Creating new repository configuration file..."
        echo "$REPOSRC" > "$REPOFILE"
        log_info "Added NetFoundry repository configuration"
    fi

    if [[ "$PRIVATE_REPO" == "true" ]]; then
        "$PACKAGER" config-manager --save --setopt=NetFoundryRelease.username="$REPO_USERNAME" NetFoundryRelease
        "$PACKAGER" config-manager --save --setopt=NetFoundryRelease.password="$REPO_PASSWORD" NetFoundryRelease
        log_info "Applied private repo credentials"
    fi

    "$PACKAGER" makecache -y
}

installRedHat(){
    configureRedHatRepo

    local PACKAGER=""
    for CMD in dnf yum; do
        if command -v "$CMD" &>/dev/null; then
            PACKAGER="$CMD"
            break
        fi
    done

    log_info "Installing packages: $*"
    if ! "$PACKAGER" install --assumeyes "$@"; then
        log_error "Package installation failed"
        exit 1
    fi

    log_info "Verifying installed packages..."
    for PKG in "$@"; do
        if "$PACKAGER" info "$PKG" >/dev/null 2>&1; then
            log_info "Successfully installed: $PKG"
        else
            log_error "Failed to verify installation of: $PKG"
        fi
    done
}

configureDebianRepo(){
    log_info "Setting up NetFoundry repository for Debian family..."

    local GNUPGCMD=""
    for CMD in gpg gpg2; do
        if command -v "$CMD" &>/dev/null; then
            GNUPGCMD="$CMD"
            log_info "Found GnuPG command: $GNUPGCMD"
            break
        fi
    done
    if [ -z "$GNUPGCMD" ]; then
        log_error "No GnuPG CLI found. Tried commands 'gpg', 'gpg2'."
        log_error "Please install 'gnupg' package: apt-get install gnupg"
        exit 1
    fi

    local GETTER=""
    local GETTERCMD=""
    for CMD in wget curl; do
        if command -v "$CMD" &>/dev/null; then
            GETTER="$CMD"
            break
        fi
    done
    if [ -z "$GETTER" ]; then
        log_error "No HTTP client found. Tried 'wget', 'curl'."
        log_error "Please install wget or curl: apt-get install wget curl"
        exit 1
    else
        case "$GETTER" in
            wget)
                GETTERCMD="wget -qO-"
                log_info "Using wget for HTTP requests"
                ;;
            curl)
                GETTERCMD="curl -fsSL"
                log_info "Using curl for HTTP requests"
                ;;
        esac
    fi

    # Always update the GPG public key
    log_info "Downloading and installing NetFoundry GPG key..."
    local KEYRING_FILE="/usr/share/keyrings/netfoundry.gpg"
    mkdir -p "$(dirname "$KEYRING_FILE")"
    if $GETTERCMD "https://${NF_REPO_HOST}/artifactory/api/security/keypair/public/repositories/${NFPAX_DEB}" \
       | $GNUPGCMD --batch --yes --dearmor --output "$KEYRING_FILE"; then
        chmod 644 "$KEYRING_FILE"
        log_info "Successfully installed NetFoundry GPG key"
    else
        log_error "Failed to download or install NetFoundry GPG key"
        exit 1
    fi

    # Detect APT version to determine repository format
    log_info "Detecting APT version for optimal repository format..."
    local APT_VERSION
    local USE_DEB822="no"
    APT_VERSION=$(apt --version 2>/dev/null | awk '{ print $2 }' | head -n 1)
    if [[ -n "$APT_VERSION" && ( "$APT_VERSION" == 2.* || "$APT_VERSION" =~ 1\.[89]* ) ]]; then
        USE_DEB822="yes"
        log_info "APT version $APT_VERSION supports DEB822 format"
    else
        log_info "APT version $APT_VERSION requires legacy format"
    fi

    local REPODIR="/etc/apt/sources.list.d"
    local REPO_BASE_NAME="netfoundry-release"
    local REPO_URL="https://${NF_REPO_HOST}/artifactory/${NFPAX_DEB}"

    # Remove old repository files (both formats)
    log_info "Cleaning up any existing repository files..."
    rm -f "${REPODIR}/${REPO_BASE_NAME}.list" "${REPODIR}/${REPO_BASE_NAME}.sources"

    if [[ "$USE_DEB822" == "yes" ]]; then
        # Use modern DEB822 format (.sources file)
        local REPOFILE="${REPODIR}/${REPO_BASE_NAME}.sources"
        local REPO_SUITES="debian"
        if [[ "$PRIVATE_REPO" == "true" ]]; then
            REPO_SUITES="debian stable"
        fi
        cat > "$REPOFILE" << EOF
Types: deb
URIs: ${REPO_URL}
Suites: ${REPO_SUITES}
Components: main
Signed-By: /usr/share/keyrings/netfoundry.gpg
EOF
        log_info "Added NetFoundry repository configuration (DEB822 format)"
    else
        # Use legacy format (.list file)
        local REPOFILE="${REPODIR}/${REPO_BASE_NAME}.list"
        local REPOSRC_DEBIAN="deb [signed-by=/usr/share/keyrings/netfoundry.gpg] ${REPO_URL} debian main"
        echo "$REPOSRC_DEBIAN" > "$REPOFILE"
        if [[ "$PRIVATE_REPO" == "true" ]]; then
            local REPOSRC_STABLE="deb [signed-by=/usr/share/keyrings/netfoundry.gpg] ${REPO_URL} stable main"
            echo "$REPOSRC_STABLE" >> "$REPOFILE"
        fi
        log_info "Added NetFoundry repository configuration (legacy format)"
    fi

    if [[ "$PRIVATE_REPO" == "true" ]]; then
        install -d -m 0700 /etc/apt/auth.conf.d
        cat > /etc/apt/auth.conf.d/netfoundry.conf <<EOF
machine ${NF_REPO_HOST}
login ${REPO_USERNAME}
password ${REPO_PASSWORD}
EOF
        chmod 600 /etc/apt/auth.conf.d/netfoundry.conf
        log_info "Private repo credentials written to /etc/apt/auth.conf.d/netfoundry.conf"
    fi

    log_info "Updating APT package metadata..."
    if ! apt-get update; then
        log_error "Failed to update APT package metadata"
        exit 1
    fi
    log_info "Successfully updated APT package metadata"
}

installDebian(){
    configureDebianRepo

    typeset -a APT_ARGS=(install --yes)
    # allow dangerous downgrades if a version is pinned with '='
    if [[ "${*}" =~ = ]]; then
        APT_ARGS+=(--allow-downgrades)
        log_info "Allowing downgrades for pinned package versions"
    fi

    log_info "Installing packages: $*"
    # shellcheck disable=SC2068
    if ! apt-get ${APT_ARGS[@]} "$@"; then
        log_error "Package installation failed"
        exit 1
    fi

    log_info "Verifying installed packages..."
    for PKG in "$@"; do
        if dpkg-query -W "${PKG%=*}" >/dev/null 2>&1; then
            local VERSION
            VERSION=$(dpkg-query -W -f='${Version}' "${PKG%=*}")
            log_info "Successfully installed: ${PKG%=*} version $VERSION"
        else
            log_error "Failed to verify installation of: ${PKG%=*}"
        fi
    done
}

showHelp(){
    cat << EOF
NetFoundry Linux Package Installer

Usage: $(basename "${BASH_SOURCE[0]:-$0}") [OPTIONS] [PACKAGE...]

Behaviors:
  1. No arguments     - Configure NetFoundry repository only
  2. With single argument   - Configure repository and install specified packages
  3. With multiple arguments - Configure private repository, install specified packages & optionally run post-exec


Options:
  --private              Configure private repository (requires --username and --password)
  --username <user>      Username for private repo
  --password <pass>      Password for private repo
  --post-exec <file>     Executable to run after package installation
  --test                 Use test repositories instead of stable
  -h, --help             Show this help message

Examples:
  # Configure repository only
  curl -sSL https://get.netfoundry.io/install.bash | sudo bash
  
  # Configure repository and install packages
  curl -sSL https://get.netfoundry.io/install.bash | sudo bash -s frontdoor-agent

  # Configure private repository and install packages
   curl -sSL https://get.netfoundry.io/install.bash | sudo bash -s --private --username myuser --password mypass frontdoor-agent
Supported distributions: Debian, Ubuntu, CentOS, RHEL, Fedora, Amazon Linux
EOF
}

detectDistribution() {
    local DISTRO_FAMILY=""
    local DISTRO_NAME="unknown"

    # Enhanced distribution detection
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO_NAME="${PRETTY_NAME:-${NAME:-${ID:-unknown}}}"
    fi

    # Detect Red Hat family
    if [[ -f /etc/redhat-release || -f /etc/amazon-linux-release || -f /etc/centos-release ]]; then
        DISTRO_FAMILY="redhat"
    elif [[ -f /etc/debian_version ]]; then
        DISTRO_FAMILY="debian"
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        # Fallback: if we have dnf/yum, assume Red Hat family
        DISTRO_FAMILY="redhat"
        log_info "Distribution detection fallback: found dnf/yum, assuming Red Hat family" >&2
    elif command -v apt-get >/dev/null 2>&1; then
        # Fallback: if we have apt-get, assume Debian family
        DISTRO_FAMILY="debian"
        log_info "Distribution detection fallback: found apt-get, assuming Debian family" >&2
    fi

    log_info "Detected distribution: $DISTRO_NAME" >&2
    echo "$DISTRO_FAMILY"
}

main(){
    # Check for help flags
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        showHelp
        exit 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --private)   PRIVATE_REPO="true"; shift ;;
            --username)  REPO_USERNAME="$2"; shift 2 ;;
            --password)  REPO_PASSWORD="$2"; shift 2 ;;
            --post-exec) POST_EXEC="$2"; shift 2 ;;
            --test)      TEST_REPO="true"; shift ;;
            --) shift; break ;;
            -*) log_error "Unknown option: $1"; exit 1 ;;
            *) break ;;
        esac
    done

    # Update repo variables based on test/stable selection
    if [[ "$PRIVATE_REPO" == "true" ]]; then
        if [[ "$TEST_REPO" == "true" ]]; then
            NFPAX_RPM="${NFPAX_RPM:-nfpax-private-rpm-test}"
            NFPAX_DEB="${NFPAX_DEB:-nfpax-private-deb-test}"
        else
            NFPAX_RPM="${NFPAX_RPM:-nfpax-private-rpm-stable}"
            NFPAX_DEB="${NFPAX_DEB:-nfpax-private-deb-stable}"
        fi
    else
        if [[ "$TEST_REPO" == "true" ]]; then
            NFPAX_RPM="${NFPAX_RPM:-nfpax-public-rpm-test}"
            NFPAX_DEB="${NFPAX_DEB:-nfpax-public-deb-test}"
        else
            NFPAX_RPM="${NFPAX_RPM:-nfpax-public-rpm-stable}"
            NFPAX_DEB="${NFPAX_DEB:-nfpax-public-deb-stable}"
        fi
    fi

    if [[ "$PRIVATE_REPO" == "true" && ( -z "$REPO_USERNAME" || -z "$REPO_PASSWORD" ) ]]; then
        log_error "--private requires both --username and --password"
        exit 1
    fi

    log_info "Starting NetFoundry package installer..."
    
    # Detect the system's distribution family
    local DISTRO_FAMILY
    DISTRO_FAMILY=$(detectDistribution)

    case "$DISTRO_FAMILY" in
        "redhat")
            if (( $# )); then
                log_info "Installing packages on Red Hat family system..."
                installRedHat "$@"
            else
                log_info "Configuring NetFoundry repository for Red Hat family..."
                configureRedHatRepo
                log_info "Repository configured. You can now install packages with: dnf install <package> or yum install <package>"
            fi
            ;;
        "debian")
            if (( $# )); then
                log_info "Installing packages on Debian family system..."
                installDebian "$@"
            else
                log_info "Configuring NetFoundry repository for Debian family..."
                configureDebianRepo
                log_info "Repository configured. You can now install packages with: apt-get install <package>"
            fi
            ;;
        *)
            log_error "Unsupported Linux distribution family: $DISTRO_FAMILY"
            log_error "NetFoundry packages are available for Debian and Red Hat family distributions."
            log_error "Supported: Ubuntu, Debian, CentOS, RHEL, Fedora, Amazon Linux, etc."
            exit 1
            ;;
    esac

    if (( $# )); then
        log_info "Package installation completed successfully"
        if [[ -n "$POST_EXEC" && -x "$POST_EXEC" ]]; then
            log_info "Running post-install executable: $POST_EXEC"
            "$POST_EXEC" || log_error "Post-install executable failed"
        fi
    else
        log_info "Repository configuration completed successfully"
    fi
}

# ensure the script is not executed before it is fully downloaded if curl'd to bash
main "$@"

# Log completion if logging is available
if [[ -w "$LOG_FILE" ]]; then
    log_info "===== [END] $(date) - NetFoundry Package Installer ====="
fi
