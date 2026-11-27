#!/usr/bin/env bash
# Offline smoke test: starts the real image from docker-compose.yml with
# network_mode: none (tests/smoke.compose.yml) and checks the security
# properties from the inside. Nothing is published and nothing leaves the host
# except the image pull.
#
#   tests/smoke.sh
#
# Uses its own Compose project names and temporary directories, so it never
# touches a running deployment, ./i2pd, ./secrets or .env. File ownership is
# set with a throwaway root container instead of sudo.
#
# Set SMOKE_SKIP_ENGINE_HEALTH=1 on engines that do not run healthchecks by
# themselves (rootless Podman without systemd); the healthcheck command is
# always run by hand as well.

# bash -c snippets below take their values as positional parameters.
# shellcheck disable=SC2016

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PROJECT="i2pd-smoke-$$"
START_TIMEOUT=${SMOKE_START_TIMEOUT:-300}

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
die() {
    printf 'ERROR %s\n' "$*" >&2
    exit 1
}

for tool in docker jq base64 od; do
    command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

# Repository defaults only.
while IFS= read -r var; do unset "$var"; done < <(compgen -e | grep '^I2PD_' || true)

# uid 100 must be able to read the mounted config (restrictive umask checkouts).
unreadable=$(find config ! -perm -o+r -o -type d ! -perm -o+x)
[ -z "$unreadable" ] || die "config/ is not world-readable; run: chmod -R a+rX config"

compose() { # compose PROJECT args...
    local project=$1
    shift
    docker compose -p "$project" --project-directory "$ROOT" \
        -f "$ROOT/docker-compose.yml" -f "$ROOT/tests/smoke.compose.yml" \
        --env-file /dev/null "$@"
}

IMAGE=$(docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" \
    --env-file /dev/null config --format json | jq -r '.services.i2pd.image')
echo "image: $IMAGE"
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null

work=$(mktemp -d)
as_root() { # run a shell snippet as root in a throwaway container with $work at /w
    docker run --rm --network none --user 0:0 -v "$work:/w" --entrypoint /bin/sh "$IMAGE" -c "$1"
}
cleanup() {
    set +e
    for p in "$PROJECT" "$PROJECT-reseed" "$PROJECT-neg"; do
        compose "$p" down --remove-orphans --timeout 5 >/dev/null 2>&1
    done
    as_root 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

share_secret() { # share_secret NAME -> group 65533 may read it, like README
    chmod 0640 "$work/$1"
    as_root "chgrp 65533 /w/$1"
}
new_secret() { # new_secret NAME CONTENT (printf %b escapes allowed)
    printf '%b' "$2" >"$work/$1"
    share_secret "$1"
}
new_datadir() { # new_datadir NAME -> owned by 100:65533, like README
    mkdir "$work/$1"
    as_root "chown 100:65533 /w/$1 && chmod 0700 /w/$1"
}

# A password with characters that need care in INI files and shells.
password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n' | head -c 24)/+=;\"\\x"
printf '%s\n' "$password" >"$work/pass"
share_secret pass
new_datadir data
export I2PD_HTTP_PASS_FILE="$work/pass" I2PD_DATA_DIR="$work/data"

# --- Start the stack ---------------------------------------------------------------

echo "starting offline stack ($PROJECT)"
compose "$PROJECT" up -d --quiet-pull >/dev/null
cid=$(compose "$PROJECT" ps -q i2pd)
[ -n "$cid" ] || die "container did not start"

health_cmd=$(docker inspect -f '{{index .Config.Healthcheck.Test 1}}' "$cid")
deadline=$((SECONDS + START_TIMEOUT))
until docker exec "$cid" sh -c "$health_cmd" >/dev/null 2>&1; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$cid")" != true ] || [ $SECONDS -ge $deadline ]; then
        docker logs "$cid" 2>&1 | tail -n 40 >&2
        die "the healthcheck command never passed"
    fi
    sleep 3
done
pass "healthcheck command passes (console 401 + SAM HELLO)"

if [ "${SMOKE_SKIP_ENGINE_HEALTH:-0}" != 1 ]; then
    until [ "$(docker inspect -f '{{.State.Health.Status}}' "$cid")" = healthy ]; do
        if [ $SECONDS -ge $deadline ]; then break; fi
        sleep 3
    done
    check "engine reports the container healthy" \
        test "$(docker inspect -f '{{.State.Health.Status}}' "$cid")" = healthy
fi

# --- Web console ----------------------------------------------------------------------

auth=$(printf 'i2pd:%s' "$password" | base64 | tr -d '\n')
badauth=$(printf 'i2pd:%s' "wrong-$password" | base64 | tr -d '\n')
status() { # status HOST [AUTH] -> HTTP status code
    {
        printf 'GET / HTTP/1.0\r\nHost: %s\r\n' "$1"
        if [ -n "${2:-}" ]; then printf 'Authorization: Basic %s\r\n' "$2"; fi
        printf '\r\n'
    } | docker exec -i "$cid" nc -w 5 127.0.0.1 7070 | head -n 1 | cut -d ' ' -f 2
}
check "console: 401 without credentials" test "$(status 127.0.0.1)" = 401
check "console: 401 with a wrong password" test "$(status 127.0.0.1 "$badauth")" = 401
check "console: 200 with the password" test "$(status 127.0.0.1:7070 "$auth")" = 200
check "console: 403 for a foreign Host (DNS rebinding)" test "$(status attacker.example "$auth")" = 403
check "console: 403 for Host localhost (hostname is 127.0.0.1)" test "$(status localhost:7070 "$auth")" = 403

# --- Listeners --------------------------------------------------------------------------

sam=$(printf 'HELLO VERSION MIN=3.0 MAX=3.3\n' | docker exec -i "$cid" nc -w 3 127.0.0.1 7656 | head -n 1)
check "SAM answers HELLO" grep -q '^HELLO REPLY RESULT=OK' <<<"$sam"
for p in 4444 7070 7656; do
    check "port $p is open" docker exec "$cid" nc -z -w 2 127.0.0.1 "$p"
done
for p in 4447:SOCKS 2827:BOB 7654:I2CP 7650:I2PControl; do
    check "port ${p%%:*} (${p#*:}) is closed" bash -c '! docker exec "$1" nc -z -w 2 127.0.0.1 "$2"' _ "$cid" "${p%%:*}"
done
published=$(docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" --env-file /dev/null \
    config --format json | jq -c '[.services.i2pd.ports[] | "\(.host_ip):\(.published)/\(.protocol)"] | sort')
check "only 127.0.0.1 TCP 4444/7070/7656 would be published" \
    test "$published" = '["127.0.0.1:4444/tcp","127.0.0.1:7070/tcp","127.0.0.1:7656/tcp"]'

# --- Password exposure -----------------------------------------------------------------------

cmdline=$(docker exec "$cid" cat /proc/1/cmdline | tr '\0' ' ')
check "PID 1 is i2pd (the entrypoint exec'd)" grep -q '^/usr/local/bin/i2pd ' <<<"$cmdline"
check "password absent from /proc/1/cmdline" bash -c '! docker exec "$1" cat /proc/1/cmdline | grep -aqF -- "$2"' _ "$cid" "$password"
check "password absent from /proc/1/environ" bash -c '! docker exec "$1" cat /proc/1/environ | grep -aqF -- "$2"' _ "$cid" "$password"
check "no password option on the command line" bash -c '! grep -qi "pass" <<<"$1"' _ "$cmdline"
check "password absent from docker inspect" bash -c '! docker inspect "$1" | grep -qF -- "$2"' _ "$cid" "$password"
check "password absent from docker compose config" \
    bash -c '! docker compose -p "$1" --project-directory "$2" -f "$2/docker-compose.yml" --env-file /dev/null config | grep -qF -- "$3"' \
    _ "$PROJECT" "$ROOT" "$password"
conf_listing=$(docker exec "$cid" sh -c 'ls -ln /run/i2pd/conf.*/i2pd.conf')
check "generated config is 0600 and owned by uid 100" grep -Eq '^-rw------- +1 +100 +65533 ' <<<"$conf_listing"
check "generated config is on tmpfs" \
    docker exec "$cid" sh -c 'awk '\''$2 == "/run/i2pd" && $3 == "tmpfs" { found = 1 } END { exit !found }'\'' /proc/mounts'
check "trust paths come from read-only locations" \
    bash -c 'for a in --conf=/run/i2pd/ --certsdir=/i2pd_certificates --tunconf=/etc/i2pd/tunnels.conf --tunnelsdir=/etc/i2pd/tunnels.d; do grep -qF -- "$a" <<<"$1" || exit 1; done' _ "$cmdline"

# --- Container hardening ---------------------------------------------------------------------

check "engine reports a read-only root filesystem" test "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$cid")" = true
for path in /probe /etc/i2pd/probe /i2pd_certificates/reseed/probe.crt /usr/local/bin/probe; do
    check "cannot write $path" bash -c '! docker exec "$1" touch "$2" 2>/dev/null' _ "$cid" "$path"
done
check "data directory is writable (positive control)" \
    docker exec "$cid" sh -c 'touch /home/i2pd/data/.probe && rm /home/i2pd/data/.probe'
status_file=$(docker exec "$cid" cat /proc/1/status)
check "runs as uid 100 / gid 65533" grep -Eq '^Uid:[[:space:]]+100[[:space:]]+100[[:space:]]+100[[:space:]]+100$' <<<"$status_file"
check "no effective or bounding capabilities" \
    bash -c 'grep -Eq "^CapEff:[[:space:]]+0+$" <<<"$1" && grep -Eq "^CapBnd:[[:space:]]+0+$" <<<"$1"' _ "$status_file"
check "no_new_privs is set" grep -Eq '^NoNewPrivs:[[:space:]]+1$' <<<"$status_file"
check "router identity written to the data directory" docker exec "$cid" test -s /home/i2pd/data/router.keys

compose "$PROJECT" down --timeout 5 >/dev/null 2>&1

# --- Reseed signature verification (offline) --------------------------------------------------
# A forged SU3 naming a signer whose certificate ships in the image must be
# rejected by signature check: this proves reseed.verify=true is in effect and
# that certificates load from the image's directory.

signer_file=$(docker run --rm --network none --entrypoint /bin/ls "$IMAGE" /i2pd_certificates/reseed | grep '\.crt$' | head -n 1)
signer=${signer_file%.crt}
signer=${signer/_at_/@}
{
    printf 'I2Psu3\0\0'                    # magic, NUL, format version
    printf '\0\006\002\0'                  # signature type 6 (RSA-SHA512-4096), length 512
    printf '\0\001\0'                      # unused, version length 1, unused
    printf '%b' "\\$(printf '%04o' "${#signer}")" # signer ID length
    printf '\0\0\0\0\0\0\0\026'            # content length 22
    printf '\0\0\0\003'                    # unused, file type zip, unused, content type reseed
    head -c 12 /dev/zero                   # unused
    printf '0%s' "$signer"                 # version, signer ID
    head -c 22 /dev/zero                   # content
    head -c 512 /dev/zero                  # signature (garbage)
} >"$work/forged.su3"
chmod 0644 "$work/forged.su3"
new_datadir data-reseed
I2PD_DATA_DIR="$work/data-reseed" compose "$PROJECT-reseed" run -d --name "$PROJECT-reseed" \
    -v "$work/forged.su3:/run/forged.su3:ro" i2pd \
    --reseed.file=/run/forged.su3 --share=0 >/dev/null
deadline=$((SECONDS + 90))
until docker logs "$PROJECT-reseed" 2>&1 | grep -q 'SU3 verification failed'; do
    [ $SECONDS -lt $deadline ] || break
    sleep 2
done
reseed_log=$(docker logs "$PROJECT-reseed" 2>&1)
check "forged SU3 from $signer rejected by signature check" grep -q 'Reseed: SU3 signature verification failed' <<<"$reseed_log"
check "unverified SU3 discarded" grep -q 'Reseed: SU3 verification failed' <<<"$reseed_log"
check "share=0 adds --notransit" bash -c 'docker exec "$1" cat /proc/1/cmdline | tr "\0" " " | grep -q -- "--notransit"' _ "$PROJECT-reseed"
docker rm -f "$PROJECT-reseed" >/dev/null 2>&1

# --- Entrypoint refusals ----------------------------------------------------------------------

expect_refusal() { # expect_refusal "description" "expected message" [VAR=value...] -- [run args...] -- [i2pd args...]
    local desc=$1 expected=$2
    shift 2
    local -a envs=() runargs=() args=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    while [ $# -gt 0 ] && [ "$1" != -- ]; do runargs+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    args=("$@")
    local out rc=0
    out=$(env "${envs[@]}" docker compose -p "$PROJECT-neg" --project-directory "$ROOT" \
        -f "$ROOT/docker-compose.yml" -f "$ROOT/tests/smoke.compose.yml" --env-file /dev/null \
        run --rm --no-deps "${runargs[@]}" i2pd "${args[@]}" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF -- "$expected" <<<"$out" && ! grep -q 'i2pd v[0-9]' <<<"$out"; then
        pass "refuses: $desc"
    else
        fail "refuses: $desc (exit $rc)"
        printf '%s\n' "$out" | tail -n 5 >&2
    fi
}

new_datadir data-neg
neg=("I2PD_DATA_DIR=$work/data-neg")
i=0
bad_secret() { # bad_secret "description" "expected" CONTENT
    i=$((i + 1))
    new_secret "bad$i" "$3"
    expect_refusal "$1" "$2" "${neg[@]}" "I2PD_HTTP_PASS_FILE=$work/bad$i" -- --
}
bad_secret "placeholder password" "placeholder" 'replace-with-a-long-random-password\n'
bad_secret "password under 16 characters" "shorter than 16" 'short-pass-1234\n'
bad_secret "multi-line password" "single line" 'first-line-long-enough-1\nsecond-line\n'
bad_secret "password followed by a blank line" "single line" 'long-enough-password-123\n\n'
bad_secret "password containing #" "'#'" 'long-enough#password-123\n'
bad_secret "leading whitespace" "whitespace" ' long-enough-password-123\n'
bad_secret "trailing whitespace" "whitespace" 'long-enough-password-123 \n'
bad_secret "CRLF line ending" "control characters" 'long-enough-password-123\r\n'
bad_secret "empty password file" "empty" ''

good=("${neg[@]}" "I2PD_HTTP_PASS_FILE=$work/pass")
expect_refusal "running as uid 0" "refusing to run as uid 0" "${good[@]}" -- --user 0:0 --
expect_refusal "--http.pass on the command line" "managed by the entrypoint" "${good[@]}" -- -- --http.pass=override-attempt
expect_refusal "-reseed.verify (single dash)" "managed by the entrypoint" "${good[@]}" -- -- -reseed.verify=false
expect_refusal "--certsdir as two tokens" "managed by the entrypoint" "${good[@]}" -- -- --certsdir /tmp
expect_refusal "--share outside 0..100" "--share must be" "${good[@]}" -- -- --share=101
expect_refusal "SAM published on 0.0.0.0" "all interfaces" "${good[@]}" I2PD_SAM_BIND_IP=0.0.0.0 -- --

printf 'long-enough-password-123\n' >"$work/unreadable"
chmod 0600 "$work/unreadable"
expect_refusal "unreadable secret, with a fix" "chgrp" "${neg[@]}" "I2PD_HTTP_PASS_FILE=$work/unreadable" -- --
mkdir "$work/data-hostowned"
chmod 0700 "$work/data-hostowned"
expect_refusal "data directory not writable, with a fix" "chown -R 100:65533" \
    "I2PD_DATA_DIR=$work/data-hostowned" "I2PD_HTTP_PASS_FILE=$work/pass" -- --

new_secret legacyshort 'too-short\n'
legacy_out=$(env "${neg[@]}" I2PD_HTTP_PASS_FILE="$work/legacyshort" I2PD_BIND_IP=192.0.2.10 \
    I2PD_HTTP_PASS=legacy-password-value-1234 \
    docker compose -p "$PROJECT-neg" --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" \
    -f "$ROOT/tests/smoke.compose.yml" --env-file /dev/null run --rm --no-deps i2pd 2>&1 || true)
check "warns about legacy I2PD_BIND_IP" grep -q 'I2PD_BIND_IP is set but no longer used' <<<"$legacy_out"
check "warns about legacy I2PD_HTTP_PASS" grep -q 'I2PD_HTTP_PASS is set but ignored' <<<"$legacy_out"
check "legacy password value never reaches the container" bash -c '! grep -qF legacy-password-value-1234 <<<"$1"' _ "$legacy_out"

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures smoke check(s) failed" >&2
    exit 1
fi
echo "all smoke checks passed"
