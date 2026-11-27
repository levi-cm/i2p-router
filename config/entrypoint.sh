#!/bin/sh
# shellcheck shell=sh
#
# Entrypoint for the hardened i2pd Compose stack. Mounted read-only and run
# with /bin/sh, so it needs no exec bit on the host.
#
#  - refuses to run as uid 0;
#  - reads the web console password from the Compose file secret and rejects
#    weak or unparseable values;
#  - writes the base config plus `[http] pass` to a 0600 file on a tmpfs;
#  - starts i2pd with read-only trust inputs: config, reseed certificates and
#    tunnel configs all live outside the writable data directory.
#
# The password never appears in argv or the environment of any process. It is
# only handled by shell builtins and written to the tmpfs file.

set -eu

I2PD_BIN=/usr/local/bin/i2pd
BASE_CONF=/etc/i2pd/i2pd.conf
SECRET_FILE=/run/secrets/i2pd_http_pass
RUNTIME_DIR=/run/i2pd
DATA_DIR=/home/i2pd/data
# Bundled with the image, root-owned, on the read-only root filesystem.
CERTS_DIR=/i2pd_certificates
# On the read-only config mount. Absent unless the admin adds them on the host.
TUNNELS_CONF=/etc/i2pd/tunnels.conf
TUNNELS_DIR=/etc/i2pd/tunnels.d
MIN_PASS_LEN=16

log() { printf 'entrypoint: %s\n' "$*" >&2; }
warn() { log "WARNING: $*"; }
die() {
    log "ERROR: $*"
    exit 1
}

uid=$(id -u)
gid=$(id -g)

# --- Identity ---------------------------------------------------------------

if [ "$uid" -eq 0 ]; then
    die "refusing to run as uid 0. Set I2PD_USER to an unprivileged uid:gid (default 100:65533)."
fi

# --- Legacy settings from the previous version --------------------------------
# docker-compose.yml passes only a "1" flag here, never the values.

if [ -n "${I2PD_LEGACY_BIND_IP_SET:-}" ]; then
    warn "I2PD_BIND_IP is set but no longer used. All ports now bind to 127.0.0.1" \
        "unless I2PD_PROXY_BIND_IP, I2PD_CONSOLE_BIND_IP or I2PD_SAM_BIND_IP is set." \
        "Remove it from .env (README: Upgrading from the previous version)."
fi
if [ -n "${I2PD_LEGACY_HTTP_PASS_SET:-}" ]; then
    warn "I2PD_HTTP_PASS is set but ignored. The console password now comes from" \
        "secrets/i2pd_http_pass. Remove it from .env and rotate the password: the" \
        "old value was visible in ps, docker inspect and docker compose config."
fi

# --- Published addresses ------------------------------------------------------
# Docker-published ports bypass host firewalls such as ufw, so a wildcard bind
# exposes the unauthenticated proxy and SAM to every network the host is on.

for pair in "proxy=${I2PD_PROXY_BIND_IP:-}" "console=${I2PD_CONSOLE_BIND_IP:-}" "sam=${I2PD_SAM_BIND_IP:-}"; do
    name=${pair%%=*}
    addr=${pair#*=}
    # Every spelling of the unspecified address: 0.0.0.0, ::, [::0], 0::0,
    # ::ffff:0.0.0.0 and so on are only zeros, colons and dots once brackets
    # and the IPv4-mapped prefix are removed.
    norm=$(printf '%s' "$addr" | tr -d '[]' | tr '[:upper:]' '[:lower:]')
    norm=${norm#::ffff:}
    case "$norm" in
        "*") wildcard=1 ;;
        "" | *[!0:.]*) wildcard= ;;
        *) wildcard=1 ;;
    esac
    if [ -n "$wildcard" ]; then
        die "the $name port is published on $addr (all interfaces). Bind it to" \
            "127.0.0.1 or one specific trusted address; Docker bypasses ufw."
    fi
done

# --- Arguments ----------------------------------------------------------------
# Command-line values override the config file in i2pd, so options that carry
# the security settings cannot be passed through. i2pd accepts --opt, -opt and
# "--opt value"; all three forms are checked.

share=
share_set=
next_is_share=
for arg in "$@"; do
    if [ -n "$next_is_share" ]; then
        share=$arg
        next_is_share=
        continue
    fi
    case "$arg" in
        --*) opt=${arg#--} ;;
        -*) opt=${arg#-} ;;
        *) continue ;;
    esac
    name=${opt%%=*}
    case "$name" in
        conf | datadir | certsdir | tunconf | tunnelsdir | http.pass | http.auth | http.strictheaders | reseed.verify)
            # Print only the option name: the value could be a password.
            die "option --$name is managed by the entrypoint and cannot be passed on the command line."
            ;;
        share)
            share_set=1
            if [ "$opt" = "$name" ]; then
                next_is_share=1
            else
                share=${opt#*=}
            fi
            ;;
    esac
done

if [ -n "$share_set" ]; then
    case "$share" in
        [0-9] | [1-9][0-9] | 100) ;;
        *) die "--share must be an integer from 0 to 100 (got '$share')." ;;
    esac
    # i2pd already refuses new transit tunnels at share=0; --notransit makes
    # that explicit.
    if [ "$share" -eq 0 ]; then
        set -- "$@" --notransit
    fi
fi

# --- Console password -----------------------------------------------------------

if [ ! -e "$SECRET_FILE" ]; then
    die "console password secret missing at $SECRET_FILE. Create secrets/i2pd_http_pass" \
        "(README: Quick start)."
fi
if [ ! -r "$SECRET_FILE" ]; then
    die "cannot read $SECRET_FILE as uid $uid gid $gid. On the host run:" \
        "sudo chgrp $gid secrets/i2pd_http_pass && chmod 0640 secrets/i2pd_http_pass" \
        "(rootless Podman: podman unshare chgrp $gid secrets/i2pd_http_pass)."
fi

pass=
# The last line may lack a newline; read still fills $pass in that case.
IFS= read -r pass <"$SECRET_FILE" || true

file_bytes=$(wc -c <"$SECRET_FILE" | tr -d ' ')
pass_bytes=$(printf '%s' "$pass" | wc -c | tr -d ' ')
pass_lower=$(printf '%s' "$pass" | tr '[:upper:]' '[:lower:]')

if [ -z "$pass" ]; then
    die "the console password in $SECRET_FILE is empty."
fi
# Exactly one line, with or without a final newline.
if [ "$file_bytes" -ne "$pass_bytes" ] && [ "$file_bytes" -ne $((pass_bytes + 1)) ]; then
    die "the console password must be a single line; $SECRET_FILE has more."
fi
case "$pass" in
    *[[:cntrl:]]*) die "the console password contains control characters (a CRLF line ending?)." ;;
esac
case "$pass" in
    [[:space:]]* | *[[:space:]])
        die "the console password has leading or trailing whitespace, which i2pd would strip."
        ;;
esac
case "$pass" in
    *"#"*) die "the console password contains '#', which i2pd treats as the start of a comment." ;;
esac
case "$pass_lower" in
    *replace-with* | *changeme* | *change-me*)
        die "the console password is still the placeholder. Generate one: openssl rand -base64 32"
        ;;
esac
if [ "$pass_bytes" -lt "$MIN_PASS_LEN" ]; then
    die "the console password is shorter than $MIN_PASS_LEN characters."
fi

# --- Trust inputs must not be writable ------------------------------------------

[ -r "$BASE_CONF" ] || die "cannot read $BASE_CONF. On the host run: chmod -R a+rX config"
ls "$CERTS_DIR"/reseed/*.crt >/dev/null 2>&1 || die "no reseed certificates in $CERTS_DIR/reseed."

for path in "$BASE_CONF" "${BASE_CONF%/*}" "$CERTS_DIR" "$CERTS_DIR/reseed" "$TUNNELS_CONF" "$TUNNELS_DIR"; do
    if [ -e "$path" ] && [ -w "$path" ]; then
        die "$path is writable by uid $uid. Keep read_only: true and mount config/ read-only."
    fi
done

# --- Data directory ---------------------------------------------------------------

if [ ! -w "$DATA_DIR" ]; then
    die "the data directory is not writable by uid $uid gid $gid, so i2pd cannot store" \
        "its router identity. On the host run: sudo chown -R $uid:$gid ./i2pd" \
        "(rootless Podman: podman unshare chown -R $uid:$gid ./i2pd)."
fi
foreign=$(find "$DATA_DIR" ! -user "$uid" 2>/dev/null | head -n 1)
if [ -n "$foreign" ]; then
    warn "$foreign (and maybe more) is not owned by uid $uid. If i2pd reports" \
        "filesystem errors, run: sudo chown -R $uid:$gid ./i2pd"
fi
for legacy in i2pd.conf tunnels.conf tunnels.d certificates; do
    if [ -e "$DATA_DIR/$legacy" ] || [ -L "$DATA_DIR/$legacy" ]; then
        log "ignoring $legacy in the data directory; config and certificates now come" \
            "from read-only paths (README: Upgrading from the previous version)."
    fi
done

# --- Effective config on tmpfs ------------------------------------------------------

runtime_fs=$(awk -v dir="$RUNTIME_DIR" '$2 == dir { fs = $3 } END { print fs }' /proc/mounts)
if [ "$runtime_fs" != tmpfs ] || [ ! -w "$RUNTIME_DIR" ]; then
    die "$RUNTIME_DIR must be a writable tmpfs so the password never touches disk."
fi

# Also inherited by i2pd: router keys and state are created 0600/0700 instead
# of the image default 0644/0755.
umask 077
conf_dir=$(mktemp -d "$RUNTIME_DIR/conf.XXXXXX")
conf=$conf_dir/i2pd.conf
{
    cat "$BASE_CONF"
    printf '\n# Appended by entrypoint.sh from the Compose secret.\n[http]\npass = %s\n' "$pass"
} >"$conf"
chmod 0600 "$conf"
unset pass pass_lower

log "starting i2pd as uid $uid gid $gid${share_set:+, transit share $share%}"

exec "$I2PD_BIN" \
    --conf="$conf" \
    --datadir="$DATA_DIR" \
    --certsdir="$CERTS_DIR" \
    --tunconf="$TUNNELS_CONF" \
    --tunnelsdir="$TUNNELS_DIR" \
    "$@"
