#!/bin/bash

set -e

# GITHUB RELEASE URL SCHEMA for concrete release artifact: https://github.com/<organisation>/<repo>/releases/download/<tag>/<concrete_artifact>
# GITHUB RELEASE URL SCHEMA for latest release artifact: https://github.com/<organisation>/<repo>/releases/latest/download/<concrete_artifact> (takes the release marked as latest)
RELEASE_URL_BASE="https://github.com/eclipse-dots/dots/releases"
DEFAULT_BIN_DESTINATION="/usr/local/bin"
BIN_DESTINATION="${DEFAULT_BIN_DESTINATION}"
DEFAULT_AGENT_OPT="--insecure --name agent_A"
AGENT_OPT="$DEFAULT_AGENT_OPT"
CONFIG_DEST="/etc/dots"
FILE_STARTUP_STATE="${CONFIG_DEST}/state.yaml"
DEFAULT_SERVER_OPT="--insecure --startup-config ${FILE_STARTUP_STATE}"
SERVER_OPT="$DEFAULT_SERVER_OPT"
INSTALL_TYPE="both"
SERVICE_DEST=/etc/systemd/system
DOTOPS_SERVICE="dotops"
FILE_DOTOPS_SERVICE="${SERVICE_DEST}/${DOTOPS_SERVICE}.service"
DOT_SERVICE="dot"
FILE_DOT_SERVICE="${SERVICE_DEST}/${DOT_SERVICE}.service"
BASEFILE_DOTCTL_UNINSTALL="dotctl-uninstall.sh"
DEFAULT_LOG_LEVEL="info"

setup_verify_arch() {
    if [ -z "$ARCH" ]; then
        ARCH=$(uname -m)
    fi
    case $ARCH in
        amd64|x86_64)
            ARCH=amd64;;
        arm64|aarch64)
            ARCH=arm64;;
        *)
            fail "Unsupported architecture '${ARCH}'."
    esac

    if [ -z "$OS_NAME" ]; then
        OS_NAME=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    case $OS_NAME in
        linux) ;;
        *)
           fail "Unsupported OS kernel type '${OS_NAME}'"
    esac
}

display_usage() {
    echo -e "Usage: $0 [-v] [-i] [-t] [-s] [-a]"
    echo -e "Install Dots on a system."
    echo -e "  -v VERSION: Dots specific VERSION to install. Default: latest version."
    echo -e "  -i PATH: Installation PATH. Default: $DEFAULT_BIN_DESTINATION"
    echo -e "  -t TARGET: Install systemd unit files for TARGET"
    echo -e "             'server', 'agent', 'none' or 'both' (default)"
    echo -e "  -s OPTIONS: OPTIONS which will be passed to the server. Default '$DEFAULT_SERVER_OPT'"
    echo -e "  -a OPTIONS: OPTIONS which will be passed to the agent. Default '$DEFAULT_AGENT_OPT'"
}

fail() {
    display_usage >&2
    if [ $# -eq 1 ]; then
        echo -e "$1"
    fi
    exit 1
}

download_release() {
    if ! curl -sfLO "$1"; then
        fail "Error: download failed. No resource under '$1'"
    fi
}

cleanup_routine() {
    if [ -d "${DOTS_TMP_DIR}" ]; then
        rm -rf "${DOTS_TMP_DIR}"
    fi
}

trap cleanup_routine EXIT

# parse script args
while getopts v:i:t:s:a: opt; do
    case $opt in
        v) DOTS_VERSION="$OPTARG";;
        i) BIN_DESTINATION="$OPTARG";;
        t) INSTALL_TYPE="$OPTARG";;
        s) SERVER_OPT="$OPTARG";;
        a) AGENT_OPT="$OPTARG";;
        *)
            fail "Error: Invalid parameter, aborting"
        ;;
    esac
done

# Use absolute path for tar -C option otherwise relative paths as script argument are failing on tar extraction
case $BIN_DESTINATION in
    /*) ;;
    *) BIN_DESTINATION="$(pwd)/${BIN_DESTINATION}";;
esac

# Fail if default or custom installation dir does not exist
if [ ! -d "${BIN_DESTINATION}" ]; then
    fail "Error: installation path '${BIN_DESTINATION}' does not exist."
fi

setup_verify_arch
SUFFIX="${OS_NAME}-${ARCH}"
echo "Platform: $SUFFIX"

RELEASE_FILE_NAME="dots-${SUFFIX}.tar.gz"
RELEASE_FILE_NAME_WITH_SHA="${RELEASE_FILE_NAME}.sha512sum.txt"

echo "Dots version: ${DOTS_VERSION}"

# In case of missing version, download latest
if [ -z "$DOTS_VERSION" ] ; then
    echo "No version provided, use default: latest"
    DOTS_RELEASE_URL="${RELEASE_URL_BASE}/latest/download/${RELEASE_FILE_NAME}"
    DOTS_RELEASE_URL_SHA="${RELEASE_URL_BASE}/latest/download/${RELEASE_FILE_NAME_WITH_SHA}"
else
    echo "Version provided, use version '${DOTS_VERSION}'"
    DOTS_RELEASE_URL="${RELEASE_URL_BASE}/download/${DOTS_VERSION}/${RELEASE_FILE_NAME}"
    DOTS_RELEASE_URL_SHA="${RELEASE_URL_BASE}/download/${DOTS_VERSION}/${RELEASE_FILE_NAME_WITH_SHA}"
fi

if [ -z "$INSTALL_DOTOPS_RUST_LOG" ] ; then
    echo "No log level for dotops provided, use default: 'info'"
    INSTALL_DOTOPS_RUST_LOG=${DEFAULT_LOG_LEVEL}
else
    echo "Log level for dotops provided: '${INSTALL_DOTOPS_RUST_LOG}'"
fi

if [ -z "$INSTALL_DOT_RUST_LOG" ]; then
    echo "No log level for dot provided, use default: 'info'"
    INSTALL_DOT_RUST_LOG=${DEFAULT_LOG_LEVEL}
else
    echo "Log level for dot provided: '${INSTALL_DOT_RUST_LOG}'"
fi

DOTS_TMP_DIR=$(mktemp -d)
echo "Creating tmp directory for download artifacts: '${DOTS_TMP_DIR}'"
cd "${DOTS_TMP_DIR}"

echo "Downloading the release: '${DOTS_RELEASE_URL}'"
download_release "${DOTS_RELEASE_URL_SHA}"
download_release "${DOTS_RELEASE_URL}"

# Skip checksum validation if sha512sum is not available
if command -v sha512sum >/dev/null; then
    echo "Checking file checksum"
    sha512sum -c "${RELEASE_FILE_NAME_WITH_SHA}"
else
    echo "Warning: 'sha512sum' not installed. Skipping checksum validation."
fi

# Prefix with sudo if install dir is not writeable with current permissions
BIN_SUDO="sudo"
if [ -w "${BIN_DESTINATION}" ]; then
    BIN_SUDO=""
fi

echo "Extracting the binaries into install folder: '${BIN_DESTINATION}'"
${BIN_SUDO} tar -xvzf "${RELEASE_FILE_NAME}" -C "${BIN_DESTINATION}/"

# Install systemd unit files
if [ -d "$SERVICE_DEST" ]; then
    SVC_SUDO="sudo"
    if [ -w "$SERVICE_DEST" ]; then
        SVC_SUDO=""
    fi

    if [[ "$INSTALL_TYPE" == dotops || "$INSTALL_TYPE" == both ]]; then
        $SVC_SUDO tee "$FILE_DOTOPS_SERVICE" >/dev/null << EOF
[Unit]
Description=Dots server

[Service]
Environment="RUST_LOG=${INSTALL_DOTOPS_RUST_LOG}"
ExecStart=${BIN_DESTINATION}/dotops $SERVER_OPT

[Install]
WantedBy=default.target
EOF
    echo "Start server with 'sudo systemctl start $DOTOPS_SERVICE'"
    fi

    if [[ "$INSTALL_TYPE" == dot || "$INSTALL_TYPE" == both ]]; then
        $SVC_SUDO tee "$FILE_DOT_SERVICE" >/dev/null << EOF
[Unit]
Description=Dots agent

[Service]
Environment="RUST_LOG=${INSTALL_DOT_RUST_LOG}"
ExecStart=${BIN_DESTINATION}/dot $AGENT_OPT

[Install]
WantedBy=default.target
EOF
    echo "Start agent with 'sudo systemctl start $DOT_SERVICE'"
    fi

else
    echo "$$SERVICE_DEST not found. Skipping installation of systemd unit files for Dots"
fi

# Write sample state startup config
if [[ "$INSTALL_TYPE" == dotops || "$INSTALL_TYPE" == both ]]; then
    if ! [ -s "$FILE_STARTUP_STATE" ]; then
        $SVC_SUDO mkdir -p "${CONFIG_DEST}"
        $SVC_SUDO tee "$FILE_STARTUP_STATE" >/dev/null << EOF
# Per default no workload is started. Adapt the file according to your needs.
apiVersion: v0.1
workloads:
#   nginx:
#     runtime: podman
#     agent: agent_A
#     restartPolicy: NEVER
#     tags:
#       - key: owner
#         value: Dots team
#     runtimeConfig: |
#       image: docker.io/nginx:latest
#       commandOptions: ["-p", "8081:80"]
EOF
        echo "Created sample startup config in $FILE_STARTUP_STATE."
    else
        echo "Skipping creation of sample startup file in $FILE_STARTUP_STATE as one already exists."
    fi
fi

# Write uninstall script
${BIN_SUDO} tee "${BIN_DESTINATION}/${BASEFILE_DOTCTL_UNINSTALL}" >/dev/null << EOF
#!/bin/bash
[ \$(id -u) -eq 0 ] || exec sudo \$0 \$@

if command -v systemctl >/dev/null; then
    if [ -s "${FILE_DOTOPS_SERVICE}" ]; then
        echo "Stopping Dots server and removing from systemd"
        systemctl stop "${DOTOPS_SERVICE}"
        systemctl disable "${DOTOPS_SERVICE}"
        systemctl daemon-reload
    fi
    if [ -s "${FILE_DOT_SERVICE}" ]; then
        echo "Stopping Dots agent and removing from systemd"
        systemctl stop "${DOT_SERVICE}"
        systemctl disable "${DOT_SERVICE}"
        systemctl daemon-reload
    fi
fi
rm -f "${FILE_DOTOPS_SERVICE}" "${FILE_DOT_SERVICE}"

echo "Removing Dots binaries"
rm -f "${BIN_DESTINATION}"/dotctl{,-server,-agent}
echo "Removing this uninstall script"
rm -f "${BIN_DESTINATION}/${BASEFILE_DOTCTL_UNINSTALL}"
EOF
${BIN_SUDO} chmod +x "${BIN_DESTINATION}/${BASEFILE_DOTCTL_UNINSTALL}"
echo "Created uninstall script ${BIN_DESTINATION}/${BASEFILE_DOTCTL_UNINSTALL}."

echo "Installation has finished."
