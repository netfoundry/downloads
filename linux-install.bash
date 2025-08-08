#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

checkSum() {
    for CMD in sha256sum md5sum; do
        if command -v $CMD &>/dev/null; then
            local SUMCMD=$CMD
            break
        fi
    done
    if [ -z "${SUMCMD:-}" ]; then
        echo "ERROR: No checksum command found. Tried 'sha256sum', 'md5sum'." >&2
        exit 1
    fi
    $SUMCMD | awk '{print $1}'
}

configureRedHatRepo(){
    for CMD in dnf yum; do
        if command -v $CMD &>/dev/null; then
            local PACKAGER=$CMD
            break
        fi
    done
    if [ -z "${PACKAGER:-}" ]; then
        echo "ERROR: No package manager found. Tried 'dnf', 'yum'." >&2
        exit 1
    fi

    local REPOSRC="[NetFoundryRelease]
name=NetFoundry Release
baseurl=https://netfoundry.jfrog.io/artifactory/${NFPAX_RPM:-nfpax-netfoundry-rpm-stable}/redhat/\$basearch
enabled=1
gpgcheck=0
gpgkey=https://netfoundry.jfrog.io/artifactory/${NFPAX_RPM:-nfpax-netfoundry-rpm-stable}/redhat/\$basearch/repodata/repomd.xml.key
repo_gpgcheck=1"

    local REPOFILE="/etc/yum.repos.d/netfoundry-release.repo"
    if [ -s $REPOFILE ]; then
        local EXISTINGSUM
        local REPOSUM
        EXISTINGSUM=$(checkSum < $REPOFILE)
        REPOSUM=$(checkSum <<< "$REPOSRC")
        if [ "$EXISTINGSUM" != "$REPOSUM" ]; then
            mv -v $REPOFILE{,".$(date -Iseconds)"}
            echo "$REPOSRC" > $REPOFILE
            echo "Updated NetFoundry repository configuration"
        else
            echo "NetFoundry repository configuration is up to date"
        fi
    else
        echo "$REPOSRC" >| $REPOFILE
        echo "Added NetFoundry repository configuration"
    fi
}

installRedHat(){
    configureRedHatRepo
    
    for CMD in dnf yum; do
        if command -v $CMD &>/dev/null; then
            local PACKAGER=$CMD
            break
        fi
    done

    $PACKAGER install --assumeyes "$@"
    for PKG in "$@"; do
        $PACKAGER info "$PKG"
    done
}

configureDebianRepo(){
    for CMD in gpg gpg2; do
        if command -v $CMD &>/dev/null; then
            local GNUPGCMD=$CMD
            break
        fi
    done
    if [ -z "${GNUPGCMD:-}" ]; then
        echo "ERROR: No GnuPG CLI found. Tried commands 'gpg', gpg2. Try installing 'gnupg'." >&2
        exit 1
    fi
    for CMD in wget curl; do
        if command -v $CMD &>/dev/null; then
            local GETTER=$CMD
            break
        fi
    done
    if [ -z "${GETTER:-}" ]; then
        echo "ERROR: No http client found. Tried 'wget', 'curl'." >&2
        exit 1
    else
        case $GETTER in
            wget)
                GETTERCMD="wget -qO-"
                ;;
            curl)
                GETTERCMD="curl -fsSL"
                ;;
        esac
    fi

    # always update the pubkey
    $GETTERCMD https://get.netfoundry.io/netfoundry.asc \
    | $GNUPGCMD --batch --yes --dearmor --output /usr/share/keyrings/netfoundry.gpg
    chmod a+r /usr/share/keyrings/netfoundry.gpg

    # Detect APT version to determine repository format
    local APT_VERSION
    local USE_DEB822="no"
    APT_VERSION=$(apt --version 2>/dev/null | awk '{ print $2 }' | head -n 1)
    if [[ -n "$APT_VERSION" && ( "$APT_VERSION" == 2.* || "$APT_VERSION" =~ 1\.[89]* ) ]]; then
        USE_DEB822="yes"
    fi

    local REPODIR="/etc/apt/sources.list.d"
    local REPO_BASE_NAME="netfoundry-release"
    local REPO_URL="https://netfoundry.jfrog.io/artifactory/${NFPAX_DEB:-nfpax-netfoundry-deb-stable}"
    
    # Remove old repository files (both formats)
    rm -f "${REPODIR}/${REPO_BASE_NAME}.list" "${REPODIR}/${REPO_BASE_NAME}.sources"
    
    if [[ "$USE_DEB822" == "yes" ]]; then
        # Use modern DEB822 format (.sources file)
        local REPOFILE="${REPODIR}/${REPO_BASE_NAME}.sources"
        cat > "$REPOFILE" << EOF
Types: deb
URIs: ${REPO_URL}
Suites: debian
Components: main
Signed-By: /usr/share/keyrings/netfoundry.gpg
EOF
        echo "Added NetFoundry repository configuration (DEB822 format)"
    else
        # Use legacy format (.list file)
        local REPOFILE="${REPODIR}/${REPO_BASE_NAME}.list"
        local REPOSRC="deb [signed-by=/usr/share/keyrings/netfoundry.gpg] ${REPO_URL} debian main"
        echo "$REPOSRC" > "$REPOFILE"
        echo "Added NetFoundry repository configuration (legacy format)"
    fi

    apt-get update
}

installDebian(){
    configureDebianRepo
    
    typeset -a APT_ARGS=(install --yes)
    # allow dangerous downgrades if a version is pinned with '='
    if [[ "${*}" =~ = ]]; then
        APT_ARGS+=(--allow-downgrades)
    fi
    # shellcheck disable=SC2068
    apt-get ${APT_ARGS[@]} "$@"
    for PKG in "$@"; do
        apt-cache show "${PKG%=*}=$(dpkg-query -W -f='${Version}' "${PKG%=*}")"
    done
}

showHelp(){
    cat << EOF
NetFoundry Linux Package Installer

Usage: $(basename "${BASH_SOURCE[0]:-$0}") [OPTIONS] [PACKAGE...]

Behaviors:
  1. No arguments     - Configure NetFoundry repository only
  2. With arguments   - Configure repository and install specified packages

Options:
  -h, --help         Show this help message

Examples:
  # Configure repository only
  curl -sSL https://get.netfoundry.io/install.bash | sudo bash
  
  # Configure repository and install packages
  curl -sSL https://get.netfoundry.io/install.bash | sudo bash -s frontdoor-agent

Supported distributions: Debian, Ubuntu, CentOS, RHEL, Fedora, Amazon Linux
EOF
}

main(){
    # Check for help flags
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        showHelp
        exit 0
    fi
    
    # Detect the system's distribution family
    if [[ -f /etc/redhat-release || -f  /etc/amazon-linux-release ]]; then
        if (( $# )); then
            installRedHat "$@"
        else
            echo "Configuring NetFoundry repository for Red Hat family..."
            configureRedHatRepo
            echo "Repository configured. You can now install packages with: dnf install <package> or yum install <package>"
        fi
    elif [ -f /etc/debian_version ]; then
        if (( $# )); then
            installDebian "$@"
        else
            echo "Configuring NetFoundry repository for Debian family..."
            configureDebianRepo
            echo "Repository configured. You can now install packages with: apt-get install <package>"
        fi
    else
        echo "ERROR: Unsupported Linux distribution family. NetFoundry packages are available for Debian and Red Hat family of distros." >&2
        exit 1
    fi
}

# ensure the script is not executed before it is fully downloaded if curl'd to bash
main "$@"
