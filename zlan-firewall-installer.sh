#!/bin/bash

###############################################################################
# Bootstrap Script for NetFoundry zLAN Firewall
#
# This script sets up authenticated private APT repos (NetFoundry) and
# public Elastic OSS repos then installs the zlan-firewall-installer package.
#
# Author: NetFoundry
# License: MIT
# Usage: ./<scripts>.sh <access_user> <access_token>
# Requirements: curl, gpg, apt
# Version: 1.0.0
###############################################################################

set -euo pipefail

# === Logging Setup ===
LOG_FILE="/var/log/zlan-firewall-installer.log"
if [[ ! -w "$(dirname "$LOG_FILE")" ]]; then
  LOG_FILE="$HOME/zlan-firewall-installer.log"
fi

log_info() {
  echo "[INFO] $*"
}
log_error() {
  echo "[ERROR] $*"
}

touch "$LOG_FILE" || {
  log_error "Cannot write to log file: $LOG_FILE"
  exit 1
}

# Redirect all output (stdout & stderr) to tee for console + log file
exec > >(tee -a "$LOG_FILE") 2>&1

log_info "===== [START] $(date) - Bootstrap Script ====="

# === Configuration ===
NF_REPO_HOST="netfoundry.jfrog.io"
AUTH_DIR="/etc/apt/auth.conf.d"
SOURCES_DIR="/etc/apt/sources.list.d"
NF_REPO_NAME="netfoundry-private-deb"
NF_REPO_URL="https://${NF_REPO_HOST}/artifactory/${NF_REPO_NAME}"
NF_KEY_URL="https://${NF_REPO_HOST}/artifactory/api/security/keypair/public/repositories/${NF_REPO_NAME}"
NF_KEYRING="/usr/share/keyrings/${NF_REPO_NAME}.gpg"
ELASTIC_REPO_NAME="elastic-oss-9x"
ELASTIC_REPO_URL="https://artifacts.elastic.co/packages/oss-9.x/apt"
ELASTIC_KEY_URL="https://artifacts.elastic.co/GPG-KEY-elasticsearch"
ELASTIC_KEYRING="/usr/share/keyrings/${ELASTIC_REPO_NAME}.gpg"

# === Input Validation ===
ACCESS_USER="${1:-}"
ACCESS_TOKEN="${2:-}"

if [[ -z "$ACCESS_USER" || -z "$ACCESS_TOKEN" ]]; then
  log_info "Usage: $0 <access_user> <access_token>"
  exit 1
fi

# === Detect Distro and Codename ===
DISTRO_ID=""
SUITE=""

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source "/etc/os-release"
  DISTRO_ID="${ID,,}"
  SUITE="$VERSION_CODENAME"
elif command -v lsb_release >/dev/null 2>&1; then
  DISTRO_ID="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
  SUITE="$(lsb_release -sc)"
elif [[ -f /etc/lsb-release ]]; then
  # shellcheck disable=SC1091
  source "/etc/lsb-release"
  # shellcheck disable=SC2153
  DISTRO_ID="${DISTRIB_ID,,}"
  SUITE="$DISTRIB_CODENAME"
fi

if [[ -z "$DISTRO_ID" || -z "$SUITE" ]]; then
  log_error "Failed to detect distro and/or codename. DISTRO_ID='$DISTRO_ID', SUITE='$SUITE'"
  exit 1
fi

log_info "Detected distro: $DISTRO_ID, suite: $SUITE"

# === Setup APT Repositories ===
setup_nf_apt() {
  log_info "Setting up NetFoundry APT repository..."

  log_info "Installing NetFoundry GPG key..."
  mkdir -p "$(dirname "$NF_KEYRING")"
  if curl -fsSL "$NF_KEY_URL" | gpg --dearmor > "$NF_KEYRING"; then
    chmod 644 "$NF_KEYRING"
  else
    log_error "Failed to fetch or write NetFoundry GPG key"
    exit 1
  fi
 
  APT_VERSION=$(apt --version 2>/dev/null | awk '{ print $2 }' | head -n 1)
  USE_DEB822="no"
  if [[ -n "$APT_VERSION" && ( "$APT_VERSION" == 2.* || "$APT_VERSION" =~ 1\.[89]* ) ]]; then
    USE_DEB822="yes"
  fi


  log_info "Removing old NetFoundry repo files..."
  rm -f "$SOURCES_DIR/${NF_REPO_NAME}.list" "$SOURCES_DIR/${NF_REPO_NAME}.sources"

  log_info "Writing repository definition..."
  if [[ "$USE_DEB822" == "yes" ]]; then
    cat <<EOF > "${SOURCES_DIR}/${NF_REPO_NAME}.sources"
Types: deb
URIs: ${NF_REPO_URL}
Suites: ${SUITE}
Components: main
Signed-By: ${NF_KEYRING}
EOF
  else
    echo "deb [signed-by=${NF_KEYRING}] ${NF_REPO_URL} ${SUITE} main" \
      > "${SOURCES_DIR}/${NF_REPO_NAME}.list"
  fi

  log_info "Setting APT credentials..."
  mkdir -p "$AUTH_DIR"
  cat <<EOF > "${AUTH_DIR}/${NF_REPO_NAME}.conf"
machine ${NF_REPO_HOST}
login ${ACCESS_USER}
password ${ACCESS_TOKEN}
EOF
  chmod 600 "${AUTH_DIR}/${NF_REPO_NAME}.conf"
}

setup_elastic_apt() {
  log_info "Setting up Elastic OSS APT repository..."

  mkdir -p "$(dirname "$ELASTIC_KEYRING")"
  if curl -fsSL "$ELASTIC_KEY_URL" | gpg --dearmor > "$ELASTIC_KEYRING"; then
    chmod 644 "$ELASTIC_KEYRING"
  else
    log_error "Failed to fetch or write Elastic GPG key"
    exit 1
  fi

  echo "deb [signed-by=${ELASTIC_KEYRING}] ${ELASTIC_REPO_URL} stable main" \
    > "${SOURCES_DIR}/${ELASTIC_REPO_NAME}.list"
}

# === Main Execution ===
log_info "Starting setup for zlan-firewall-installer..."
case "$DISTRO_ID" in
  debian|ubuntu)
    setup_nf_apt
    setup_elastic_apt
    log_info "Updating APT metadata..."
    if ! apt-get update; then
      log_error "apt-get update failed"
      exit 1
    fi
    ;;
  *)
    log_error "Unsupported distribution: $DISTRO_ID"
    exit 1
    ;;
esac

log_info "Installing zlan-firewall-installer..."
if ! apt-get install -y zlan-firewall-installer; then
  log_error "Installation failed: zlan-firewall-installer"
  exit 1
fi

log_info "[SUCCESS] zlan-firewall-installer installed."
log_info "===== [END] $(date) ====="
