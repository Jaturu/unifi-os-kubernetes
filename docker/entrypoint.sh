#!/bin/bash
# UniFi OS Server container entrypoint.
#
# Prepares per-container state (UUID, version string, log/data dirs) and then
# hands control to systemd, which boots the bundled UOS service stack
# (mongodb, postgresql, rabbitmq, nginx, java network app, go services, ...).

set -euo pipefail

DATA_DIR="${UOS_DATA_DIR:-/data}"

# 1. Persist a stable UOS_UUID across container restarts.
if [ ! -f "$DATA_DIR/uos_uuid" ]; then
    if [ -n "${UOS_UUID:-}" ]; then
        echo "Persisting supplied UOS_UUID=$UOS_UUID"
        printf '%s' "$UOS_UUID" > "$DATA_DIR/uos_uuid"
    else
        RAW_UUID=$(cat /proc/sys/kernel/random/uuid)
        # Force the version nibble to 5 so UOS treats the id as a v5 UUID.
        UOS_UUID="${RAW_UUID:0:14}5${RAW_UUID:15}"
        echo "Generated UOS_UUID=$UOS_UUID"
        printf '%s' "$UOS_UUID" > "$DATA_DIR/uos_uuid"
    fi
fi

# 2. Write the UOS identity files the bundled services expect.
# /usr/lib/version is the firmware version string read by `uos runnable`.
# /usr/lib/app_model is the console model key ubnt-tools passes to unifi-core
# (APP_MODEL=$(cat /usr/lib/app_model)) for its boardSysIds lookup; when it's
# missing the model resolves to "" and unifi-core crash-loops on boot with
# `Unsupported console model: ""` (issue #18). UOSSERVER (sysid 0xae01) matches
# the prefix in the version string above. /usr/lib/product_name is read
# unconditionally by ubnt-tools (non-fatal, but noisy when absent).
echo "Setting UOS_SERVER_VERSION=${UOS_SERVER_VERSION}"
echo "UOSSERVER.0000000.${UOS_SERVER_VERSION}.0000000.000000.0000" > /usr/lib/version
echo "UOSSERVER" > /usr/lib/app_model
echo "UniFi OS Server" > /usr/lib/product_name

# 3. Map dpkg arch to UOS firmware platform.
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64) FIRMWARE_PLATFORM=linux-x64 ;;
    arm64) FIRMWARE_PLATFORM=arm64 ;;
    *)
        echo "Unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac
echo "Setting FIRMWARE_PLATFORM=$FIRMWARE_PLATFORM"
echo "$FIRMWARE_PLATFORM" > /usr/lib/platform

# 4. UOS expects an eth0; alias it to tap0 if present (macvlan setups).
if [ ! -d /sys/devices/virtual/net/eth0 ] && [ -d /sys/devices/virtual/net/tap0 ]; then
    ip link add name eth0 link tap0 type macvlan
    ip link set eth0 up
fi

# 5. Ensure runtime directories exist with correct ownership.
ensure_dir() {
    local path="$1" owner="$2" mode="$3"
    if [ ! -d "$path" ]; then
        mkdir -p "$path"
    fi
    chown -R "$owner" "$path"
    chmod "$mode" "$path"
}

ensure_dir /var/log/nginx     nginx:nginx     755
ensure_dir /var/log/mongodb   mongodb:mongodb 755
ensure_dir /var/log/rabbitmq  rabbitmq:rabbitmq 755

# /var/lib/mongodb needs to be owned by mongodb AND not world-writable.
# When the path comes from a freshly-provisioned NFS PV the default mode is
# often 0777, which mongod refuses (and on some NFS servers the underlying
# uid mapping then refuses subsequent lock-file stats). Force-chown and
# chmod to 0770 so the bundled mongod boots cleanly.
# Only re-own when the top-level owner is wrong, so a large datadir isn't
# walked on every boot. Failures stay non-fatal (root-squashed NFS exports
# reject chown) but are reported, since mongod will otherwise fail later
# with a much less obvious error.
mkdir -p /var/lib/mongodb
if [ "$(stat -c '%U:%G' /var/lib/mongodb)" != "mongodb:mongodb" ]; then
    chown -R mongodb:mongodb /var/lib/mongodb \
        || echo "WARNING: could not chown /var/lib/mongodb to mongodb:mongodb; mongod may fail to start" >&2
fi
chmod 0770 /var/lib/mongodb \
    || echo "WARNING: could not chmod /var/lib/mongodb to 0770; mongod may fail to start" >&2

# 6. Synology-specific systemd unit overrides (DSM cgroup quirks).
SYS_VENDOR="/sys/class/dmi/id/sys_vendor"
if { [ -f "$SYS_VENDOR" ] && grep -q Synology "$SYS_VENDOR"; } \
    || [ "${HARDWARE_PLATFORM:-}" = "synology" ]; then
    echo "Synology hardware detected, applying systemd overrides"

    mkdir -p /etc/systemd/system/postgresql@14-main.service.d
    cat > /etc/systemd/system/postgresql@14-main.service.d/override.conf <<EOF
[Service]
PIDFile=
EOF

    mkdir -p /etc/systemd/system/rabbitmq-server.service.d
    cat > /etc/systemd/system/rabbitmq-server.service.d/override.conf <<EOF
[Service]
Type=simple
EOF

    mkdir -p /etc/systemd/system/ulp-go.service.d
    cat > /etc/systemd/system/ulp-go.service.d/override.conf <<EOF
[Service]
Type=simple
EOF
fi

# 7. Redirect Go-service logs to stdout so `kubectl logs` / docker logs see them.
# These services read their settings from /data/<svc>/ws/config.props and default
# to logging into per-service files inside the container, which are invisible to
# standard log aggregation. We append the log-redirect properties idempotently:
# if the file already sets `log.std` (to any value) we leave it alone, so user
# customizations survive container restarts and the block is never appended twice.
ensure_log_redirect() {
    local cfg="$1"
    local dir
    dir="$(dirname "$cfg")"
    mkdir -p "$dir"
    if [ -f "$cfg" ] && grep -qE '^[[:space:]]*log\.std[[:space:]]*=' "$cfg"; then
        return 0
    fi
    {
        echo ""
        echo "# Added by uos-entrypoint: redirect logs to stdout for container log aggregation"
        echo "log.std = true"
        echo "log.redirect_std_output = false"
        echo "log.std_to_file.enable = false"
    } >> "$cfg"
}

for svc in ulp-go ucs-agent unifi-directory uid-agent unifi-credential-server \
           ucs-user-assets unifi-identity-update; do
    ensure_log_redirect "$DATA_DIR/$svc/ws/config.props"
done

# 8. Optional: pin system_ip in unifi network properties.
UNIFI_SYSTEM_PROPERTIES="/var/lib/unifi/system.properties"
if [ -n "${UOS_SYSTEM_IP:-}" ]; then
    # The value is spliced into a sed expression and a properties file; only
    # accept hostname / IPv4 / IPv6 characters.
    if ! [[ "$UOS_SYSTEM_IP" =~ ^[A-Za-z0-9.:_-]+$ ]]; then
        echo "Invalid UOS_SYSTEM_IP (expected a hostname or IP address): $UOS_SYSTEM_IP" >&2
        exit 1
    fi
    echo "Setting system_ip=$UOS_SYSTEM_IP in $UNIFI_SYSTEM_PROPERTIES"
    mkdir -p "$(dirname "$UNIFI_SYSTEM_PROPERTIES")"
    if [ -f "$UNIFI_SYSTEM_PROPERTIES" ] && grep -q '^system_ip=' "$UNIFI_SYSTEM_PROPERTIES"; then
        sed -i "s|^system_ip=.*|system_ip=$UOS_SYSTEM_IP|" "$UNIFI_SYSTEM_PROPERTIES"
    else
        echo "system_ip=$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
    fi
fi

# 9. Hand DISCOVERY_SHIM_* overrides to the discovery shim unit. systemd does
# not pass the container environment on to services, so write the ones that
# are set to the unit's EnvironmentFile (rewritten each boot, so removing an
# override takes effect on restart).
SHIM_ENV_FILE=/etc/default/uos-discovery-shim
: > "$SHIM_ENV_FILE"
for var in DISCOVERY_SHIM_NODE DISCOVERY_SHIM_PORT DISCOVERY_SHIM_HOST; do
    if [ -n "${!var:-}" ]; then
        printf '%s=%s\n' "$var" "${!var}" >> "$SHIM_ENV_FILE"
    fi
done

exec /sbin/init
