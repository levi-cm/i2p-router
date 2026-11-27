#!/usr/bin/env bash
# Static checks on the rendered Compose model and the repository contents.
# Needs: docker compose, jq, git, shellcheck. Starts no containers.
#
#   tests/static-checks.sh
#
# Runs against repository defaults: the local .env and any I2PD_* variables in
# your shell are ignored.

# bash -c snippets below take their values as positional parameters.
# shellcheck disable=SC2016

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

failures=0
pass() { printf 'ok    %s\n' "$*"; }
fail() {
    printf 'FAIL  %s\n' "$*" >&2
    failures=$((failures + 1))
}
check() { # check "description" command...
    local desc=$1
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

for tool in docker jq git shellcheck; do
    command -v "$tool" >/dev/null || {
        echo "missing required tool: $tool" >&2
        exit 2
    }
done

# Repository defaults only.
while IFS= read -r var; do unset "$var"; done < <(compgen -e | grep '^I2PD_' || true)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A sentinel stands in for the console password, plus a legacy .env password.
sentinel="sentinel-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
legacy_sentinel="legacy-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$sentinel" >"$work/pass"
export I2PD_HTTP_PASS_FILE="$work/pass"

render() { # render [VAR=value...] -> JSON model on stdout
    env "$@" docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" \
        --env-file /dev/null config --format json
}
jqcheck() { # jqcheck "description" file filter [jq args...]
    local desc=$1 file=$2 filter=$3
    shift 3
    if jq -e "$@" "$filter" "$file" >/dev/null; then pass "$desc"; else fail "$desc"; fi
}

docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" --env-file /dev/null config --quiet
render >"$work/default.json"
M="$work/default.json"
S='.services.i2pd'

# --- Exposure defaults ---------------------------------------------------------

jqcheck "exactly three published ports (4444, 7070, 7656), all TCP" "$M" \
    "[$S.ports[] | {t: .target, p: (.protocol // \"tcp\")}] | sort_by(.t) == [{t:4444,p:\"tcp\"},{t:7070,p:\"tcp\"},{t:7656,p:\"tcp\"}]"
jqcheck "every published port binds to 127.0.0.1 by default" "$M" \
    "all($S.ports[]; .host_ip == \"127.0.0.1\")"
jqcheck "published host port equals container port" "$M" \
    "all($S.ports[]; (.published | tostring) == (.target | tostring))"
jqcheck "entrypoint sees loopback bind addresses by default" "$M" \
    "$S.environment | .I2PD_PROXY_BIND_IP == \"127.0.0.1\" and .I2PD_CONSOLE_BIND_IP == \"127.0.0.1\" and .I2PD_SAM_BIND_IP == \"127.0.0.1\""
jqcheck "console hostname defaults to 127.0.0.1" "$M" \
    "$S.command | index(\"--http.hostname=127.0.0.1\") != null"
jqcheck "no host networking, no shared namespaces" "$M" \
    "[$S | .network_mode, .pid, .ipc, .userns_mode, .uts, .cgroup] | all(. == null)"

for svc in PROXY:4444 CONSOLE:7070 SAM:7656; do
    name=${svc%%:*}
    port=${svc#*:}
    render "I2PD_${name}_BIND_IP=192.0.2.10" >"$work/optin.json"
    jqcheck "I2PD_${name}_BIND_IP moves only port $port" "$work/optin.json" \
        "all($S.ports[]; if .target == $port then .host_ip == \"192.0.2.10\" else .host_ip == \"127.0.0.1\" end)
         and $S.environment.I2PD_${name}_BIND_IP == \"192.0.2.10\""
done
# Set but empty, as a blank line in .env does. ${VAR-default} would publish on all interfaces.
render I2PD_PROXY_BIND_IP= I2PD_CONSOLE_BIND_IP= I2PD_SAM_BIND_IP= >"$work/empty-bind.json"
jqcheck "empty bind variables fall back to 127.0.0.1" "$work/empty-bind.json" \
    "all($S.ports[]; .host_ip == \"127.0.0.1\")
     and ($S.environment | .I2PD_PROXY_BIND_IP == \"127.0.0.1\" and .I2PD_CONSOLE_BIND_IP == \"127.0.0.1\" and .I2PD_SAM_BIND_IP == \"127.0.0.1\")"
render I2PD_CONSOLE_BIND_IP=192.0.2.10 >"$work/console.json"
jqcheck "console hostname follows I2PD_CONSOLE_BIND_IP" "$work/console.json" \
    "$S.command | index(\"--http.hostname=192.0.2.10\") != null"
render I2PD_CONSOLE_BIND_IP=192.0.2.10 I2PD_CONSOLE_HOSTNAME=router.example >"$work/hostname.json"
jqcheck "I2PD_CONSOLE_HOSTNAME overrides the console hostname" "$work/hostname.json" \
    "$S.command | index(\"--http.hostname=router.example\") != null"

render "I2PD_BIND_IP=192.0.2.10" >"$work/legacy-bind.json"
jqcheck "legacy I2PD_BIND_IP no longer moves any port" "$work/legacy-bind.json" \
    "all($S.ports[]; .host_ip == \"127.0.0.1\") and $S.environment.I2PD_LEGACY_BIND_IP_SET == \"1\""

if [ -f .env.example ]; then
    docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" \
        --env-file .env.example config --format json >"$work/example.json"
    jqcheck ".env.example keeps every port on 127.0.0.1" "$work/example.json" \
        "all($S.ports[]; .host_ip == \"127.0.0.1\")"
    check ".env.example sets no password, legacy variable or image pin" \
        bash -c '! grep -Eq "^[[:space:]]*(I2PD_HTTP_PASS|I2PD_BIND_IP|I2PD_IMAGE)[[:space:]]*=" .env.example'
else
    fail ".env.example exists"
fi

# --- Secrets ------------------------------------------------------------------

render "I2PD_HTTP_PASS=$legacy_sentinel" "I2PD_BIND_IP=192.0.2.10" >"$work/secret.json"
env "I2PD_HTTP_PASS=$legacy_sentinel" docker compose --project-directory "$ROOT" \
    -f "$ROOT/docker-compose.yml" --env-file /dev/null config >"$work/secret.yaml"
check "rendered model never contains the password (JSON and YAML)" \
    bash -c '! grep -qF -e "$1" -e "$2" "$3" "$4"' _ "$sentinel" "$legacy_sentinel" "$work/secret.json" "$work/secret.yaml"
jqcheck "no password option in command or entrypoint" "$work/secret.json" \
    "[($S.command // [])[], ($S.entrypoint // [])[]] | all(test(\"pass\"; \"i\") | not)"
jqcheck "environment carries only flags for legacy settings" "$work/secret.json" \
    "$S.environment.I2PD_LEGACY_HTTP_PASS_SET == \"1\"
     and ([$S.environment | to_entries[] | select(.key | test(\"PASS|SECRET|TOKEN\"; \"i\"))] | all(.value == \"\" or .value == \"1\"))"
jqcheck "console password comes from a file secret" "$M" \
    "($S.secrets | map(.source) | index(\"i2pd_http_pass\") != null) and (.secrets.i2pd_http_pass.file | type == \"string\")"
check "config/i2pd.conf does not set a password" \
    bash -c '! grep -Eq "^[[:space:]]*pass[[:space:]]*=" config/i2pd.conf'

# --- Container hardening -------------------------------------------------------

jqcheck "runs as 100:65533 by default" "$M" "$S.user == \"100:65533\""
jqcheck "read-only root filesystem" "$M" "$S.read_only == true"
jqcheck "all capabilities dropped, none added" "$M" "$S.cap_drop == [\"ALL\"] and (($S.cap_add // []) | length == 0)"
jqcheck "security_opt is exactly no-new-privileges (no unconfined profiles)" "$M" \
    "$S.security_opt == [\"no-new-privileges:true\"]"
jqcheck "not privileged, no devices" "$M" "($S.privileged // false) == false and (($S.devices // []) | length == 0)"
jqcheck "no supplementary groups" "$M" "($S.group_add // []) | length == 0"
jqcheck "noexec tmpfs on /tmp and /run/i2pd" "$M" \
    "[$S.tmpfs[] | select(test(\"^/(tmp|run/i2pd):\") and test(\"noexec\") and test(\"nosuid\") and test(\"size=\"))] | length == 2"
jqcheck "memory, PID and CPU limits set" "$M" \
    "(($S.mem_limit // 0) | tonumber) > 0 and ($S.pids_limit // 0) > 0 and (($S.cpus // 0) | tonumber) > 0"
jqcheck "entrypoint is the mounted script" "$M" "$S.entrypoint == [\"/bin/sh\", \"/etc/i2pd/entrypoint.sh\"]"
# Command-line options override i2pd.conf, so this list is the only guard against them.
jqcheck "command is exactly the four default options" "$M" \
    "$S.command == [\"--http.user=i2pd\", \"--http.hostname=127.0.0.1\", \"--bandwidth=O\", \"--share=50\"]"
jqcheck "bandwidth O with a share" "$M" \
    "($S.command | index(\"--bandwidth=O\") != null) and ($S.command | any(test(\"^--share=[0-9]+$\")))"
jqcheck "healthcheck needs a 401 from the console and a SAM HELLO reply" "$M" \
    "($S.healthcheck.test | join(\" \")) | test(\"7070\") and test(\" 401\") and test(\"7656\") and test(\"HELLO REPLY RESULT=OK\")"

# --- Mounts -----------------------------------------------------------------------

jqcheck "config/ is mounted read-only at /etc/i2pd" "$M" \
    "any($S.volumes[]; .target == \"/etc/i2pd\" and .read_only == true and (.source | endswith(\"/config\")))"
jqcheck "data directory is the only writable mount" "$M" \
    "[$S.volumes[] | select((.read_only // false) | not) | .target] == [\"/home/i2pd/data\"]"
# A named volume here would silently give upgraders a new router identity.
jqcheck "data directory is a bind mount of ./i2pd by default" "$M" \
    "[$S.volumes[] | select(.target == \"/home/i2pd/data\") | {type, source}] == [{type: \"bind\", source: (\$root + \"/i2pd\")}]" \
    --arg root "$ROOT"
render I2PD_DATA_DIR=/srv/i2pd-test >"$work/datadir.json"
jqcheck "I2PD_DATA_DIR moves the data bind mount" "$work/datadir.json" \
    "[$S.volumes[] | select(.target == \"/home/i2pd/data\") | {type, source}] == [{type: \"bind\", source: \"/srv/i2pd-test\"}]"
jqcheck "no Docker socket or host root mounted" "$M" \
    "all($S.volumes[]; (.source // \"\") as \$s | (\$s | test(\"docker\\\\.sock\") | not) and \$s != \"/\")"

# --- i2pd.conf --------------------------------------------------------------------

# One section.key=value line per setting, parsed as i2pd does: '#' starts a
# comment anywhere, whitespace around names and values is ignored, and keys
# before the first [section] have no prefix.
awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
    $0 == "" { next }
    /^\[.*\]$/ { s = substr($0, 2, length($0) - 2); gsub(/[[:space:]]/, "", s); s = s "."; next }
    { k = $0; sub(/[[:space:]]*=.*/, "", k); v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); print s k "=" v }' \
    config/i2pd.conf >"$work/conf.kv"
conf_is() { # conf_is key value: key is set exactly once, to value
    [ "$(awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2) }' "$work/conf.kv")" = "$2" ]
}
for pin in floodfill=false ipv4=true ipv6=false upnp.enabled=false reseed.verify=true \
    http.auth=true http.strictheaders=true httpproxy.senduseragent=false socksproxy.enabled=false \
    bob.enabled=false i2cp.enabled=false i2pcontrol.enabled=false \
    limits.transittunnels=2500 limits.openfiles=4096; do
    check "i2pd.conf sets $pin" conf_is "${pin%%=*}" "${pin#*=}"
done
check "i2pd.conf sets no outproxy" bash -c '! grep -q "^[^=]*outproxy[^=]*=" "$1"' _ "$work/conf.kv"

# --- Image pin ---------------------------------------------------------------------

image=$(jq -r "$S.image" "$M")
check "default image is a release tag pinned by digest ($image)" \
    bash -c '[[ $1 =~ ^purplei2p/i2pd:release-[0-9]+(\.[0-9]+)+@sha256:[0-9a-f]{64}$ ]]' _ "$image"
version=${image#*:release-}
version=${version%@*}
check "README names the pinned release ($version)" grep -qF "release-$version" README.md
override="example.invalid/i2pd:reviewed@sha256:$(printf 'a%.0s' {1..64})"
render "I2PD_IMAGE=$override" >"$work/override.json"
jqcheck "I2PD_IMAGE overrides the image" "$work/override.json" "$S.image == \"$override\""

# --- Workflows -----------------------------------------------------------------

unpinned=$(grep -HnE '^[[:space:]-]*uses:' .github/workflows/*.y*ml |
    grep -vE 'uses:[[:space:]]*["'\'']?(\./|[^@[:space:]]+@[0-9a-f]{40}([[:space:]"'\'']|$)|docker://[^@[:space:]]+@sha256:[0-9a-f]{64})' || true)
if [ -z "$unpinned" ]; then pass "workflow actions pinned to full commit SHAs"; else
    fail "workflow actions pinned to full commit SHAs:"
    printf '      %s\n' "$unpinned" >&2
fi

# --- Repository contents -------------------------------------------------------------

# Tracked files plus new files that are not ignored.
mapfile -d '' files < <(git ls-files -z --cached --others --exclude-standard)
existing=()
for f in "${files[@]}"; do [ -f "$f" ] && existing+=("$f"); done

private_re='(^|[^0-9.])('
private_re+='10(\.[0-9]{1,3}){3}'
private_re+='|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2}'
private_re+='|192\.168(\.[0-9]{1,3}){2}'
private_re+='|169\.254(\.[0-9]{1,3}){2}'
private_re+='|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])(\.[0-9]{1,3}){2}'
private_re+=')($|[^0-9])'
hits=$(grep -HnIE "$private_re" "${existing[@]}" || true)
if [ -z "$hits" ]; then pass "no private, link-local or Tailscale IPv4 addresses"; else
    fail "no private, link-local or Tailscale IPv4 addresses:"
    printf '      %s\n' "$hits" >&2
fi
hits=$(grep -HnIiE 'fd7a:115c:a1e[0]:|\.ts\.net([^a-z0-9-]|$)|\.tailscale\.net' "${existing[@]}" || true)
if [ -z "$hits" ]; then pass "no Tailscale IPv6 addresses or tailnet hostnames"; else
    fail "no Tailscale IPv6 addresses or tailnet hostnames:"
    printf '      %s\n' "$hits" >&2
fi
# shellcheck disable=SC1003 # literal backslashes in a Windows path pattern
hits=$(grep -HnIE '/home/[a-z_][a-z0-9_.-]*/|/Users/[A-Za-z0-9_.-]+/|[A-Za-z]:\\Users\\' "${existing[@]}" |
    grep -vE '/home/i2pd/' || true)
if [ -z "$hits" ]; then pass "no personal home directory paths"; else
    fail "no personal home directory paths:"
    printf '      %s\n' "$hits" >&2
fi

check "no .env or secrets tracked" bash -c '[ -z "$(git ls-files .env secrets)" ] && [ "$(git ls-files ".env.*")" = ".env.example" ]'
check "only i2pd/.gitkeep tracked in the data directory" bash -c '[ "$(git ls-files i2pd)" = "i2pd/.gitkeep" ]'
for path in .env .env.local secrets/i2pd_http_pass i2pd/router.keys i2pd/router.info i2pd/netDb/x \
    config/tunnels.conf config/tunnels.d/x.conf; do
    check "git ignores $path" git check-ignore --no-index -q "$path"
done
for entry in .env secrets/ i2pd/; do
    check ".dockerignore excludes $entry" grep -Fxq "$entry" .dockerignore
done

# --- Shell scripts ------------------------------------------------------------------------

check "shellcheck config/entrypoint.sh (POSIX sh)" shellcheck -s sh config/entrypoint.sh
check "shellcheck tests/*.sh (bash)" shellcheck -s bash tests/*.sh
check "entrypoint has no bashisms for busybox ash" bash -c 'head -n 1 config/entrypoint.sh | grep -qx "#!/bin/sh"'

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures static check(s) failed" >&2
    exit 1
fi
echo "all static checks passed"
