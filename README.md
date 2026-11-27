# I2P Router Docker Compose

This project runs an [i2pd](https://i2pd.website/) router with an HTTP proxy,
a web console and a SAM bridge through Docker Compose, for local `.i2p`
browsing and local I2P-aware applications. It is not an I2P hidden service host
and must never be published as an open proxy.

It is secure by default:

- every port is published on `127.0.0.1` only, and each service has its own
  opt-in variable for wider exposure;
- the console password comes from a Compose file secret and never appears in
  `ps`, `docker inspect` or `docker compose config`;
- the i2pd config, reseed certificates and tunnel definitions are read-only,
  and reseed signatures are verified;
- the container runs unprivileged with a read-only root filesystem, no
  capabilities and resource limits.

> **Upgrading from the version that used `I2PD_BIND_IP` and `I2PD_HTTP_PASS`?**
> This release has breaking changes. Follow
> [Upgrading from the previous version](#upgrading-from-the-previous-version).

## Quick start

Run these commands from the repository directory. You need Docker Engine with
Compose v2 and `openssl`. For rootless Podman, see the next section.

```bash
# 1. Console password, stored as a Compose file secret (never in .env).
mkdir -p secrets
(umask 077 && openssl rand -base64 32 > secrets/i2pd_http_pass)

# 2. Give the container user (uid 100, gid 65533) access to its files.
sudo chgrp 65533 secrets/i2pd_http_pass && chmod 0640 secrets/i2pd_http_pass
sudo chown -R 100:65533 i2pd
chmod -R a+rX config

# 3. Start the router.
docker compose up -d
docker compose ps
```

What each ownership step is for:

- The image runs i2pd as uid 100, gid 65533. It cannot write a data directory
  owned by your login user, which made the previous quick start crash with
  `filesystem_error`. `./i2pd` holds the router identity, so it must belong to
  the container user. On the host, `ls -l` may show uid 100 as an unrelated
  system account; that is only a name lookup. i2pd creates its files 0600
  and its directories 0700, so the router keys stay private. If `git status`
  then warns that it cannot open `i2pd/` or `i2pd/.gitkeep`, run
  `sudo chmod 0755 i2pd && sudo chmod a+r i2pd/.gitkeep`: this reveals only
  the file names and the empty `.gitkeep`.
- You keep owner access to the password file, and the container reads it
  through group 65533. To see the password, run `cat secrets/i2pd_http_pass`.
- `config/` is mounted read-only and must be readable by uid 100. The `chmod`
  only matters if your umask is restrictive (for example 077).
- If you cannot use `sudo`, set `I2PD_USER=<your-uid>:<your-gid>` in `.env`
  instead. The container then runs with your own uid, so it can use your files
  as they are. It must not be 0.

After startup:

| What | Where |
|---|---|
| Web console | <http://127.0.0.1:7070>, user `i2pd`, password from `secrets/i2pd_http_pass` |
| HTTP proxy | `127.0.0.1:4444` |
| SAM bridge | `127.0.0.1:7656` |

Open the console as `http://127.0.0.1:7070`, not `http://localhost:7070`.
The console answers `403 host mismatch` when the browser's Host header is not
the configured hostname (see `I2PD_CONSOLE_HOSTNAME`).

On first start the router has to reseed (download signed bootstrap data) and
build tunnels. `docker compose ps` shows `healthy` once the console and SAM are
up. Give it a few minutes before expecting `.i2p` sites to load reliably.
The address book downloads its first host list about three minutes after the
first start, and that first list is short. Until then, and for sites not on
it, names fail with "Host not found"; use the site's `.b32.i2p` address or a
jump service.

### Rootless Podman

In rootless Podman, uid 0 inside the container is your own user, and
container uid 100 maps to one of your subordinate uids. Use `podman unshare`
instead of `sudo` so the ownership is set inside that user namespace:

```bash
mkdir -p secrets
(umask 077 && openssl rand -base64 32 > secrets/i2pd_http_pass)
podman unshare chgrp 65533 secrets/i2pd_http_pass && chmod 0640 secrets/i2pd_http_pass
podman unshare chown -R 100:65533 i2pd
chmod -R a+rX config
podman compose up -d
```

- Do not set `I2PD_USER=0:0` to avoid the ownership step. The entrypoint
  refuses uid 0, even though rootless "root" is your own user.
- Without systemd (for example inside another container or on WSL), Podman
  never runs healthchecks on its own, so the status stays `starting`. Run
  `podman healthcheck run <container>` by hand. That is expected behaviour,
  not a fault in this stack.
- The memory, PID and CPU limits need cgroup v2 controllers delegated to your
  user. If Podman reports a missing controller, enable delegation, or override
  the limit in a local `compose.override.yml`.
- On SELinux-enforcing hosts, label the mounted paths once:
  `chcon -Rt container_file_t config i2pd secrets`.

## What is exposed

| Service | Port | Default host binding | Opt-in variable | Authentication | If someone else can reach it |
|---|---|---|---|---|---|
| HTTP proxy | 4444/tcp | `127.0.0.1` | `I2PD_PROXY_BIND_IP` | none | They browse `.i2p` as your router. There is no outproxy, so no clearnet. |
| Web console | 7070/tcp | `127.0.0.1` | `I2PD_CONSOLE_BIND_IP` | HTTP Basic over plain HTTP, plus a Host header check | Router status and control: shutdown, transit, tunnels, destinations. |
| SAM bridge | 7656/tcp | `127.0.0.1` | `I2PD_SAM_BIND_IP` | none | Roughly shell-level. They can create destinations, and `STREAM FORWARD` makes the container connect to any host and port it can reach, including your LAN. |
| SAM datagrams | 7655/udp | not published | none | none | Container-only. i2pd always opens it together with SAM. |
| SOCKS 4447, BOB 2827, I2CP 7654, I2PControl 7650 | none | disabled | none | none | Not running. |
| I2P transports (NTCP2, SSU2) | random | not published | none | none | No inbound port is forwarded. The router runs firewalled and other routers reach it only through SSU2 introducers, which is fine for client use. |

i2pd listens on `0.0.0.0` inside the container because published ports
arrive on the container's `eth0`. Exposure on the host is decided only by
`ports:` in `docker-compose.yml`.

Host applications reach SAM through Docker's port forwarding, so i2pd sees
them as the bridge gateway address, not `127.0.0.1`. Use `STREAM ACCEPT`, or
`STREAM FORWARD` with a `HOST=` the container can reach: without `HOST`, i2pd
forwards to the gateway address, which a service listening only on
`127.0.0.1` never receives. Datagram and raw sessions need 7655/udp, which is
not published.

## Threat model

**Protected against:**

- **Other machines on your networks.** Nothing is reachable from another host
  by default. The entrypoint refuses to start if any service is published on
  `0.0.0.0` or `::`.
- **Web pages in your browser.** A DNS-rebinding page gets `401` and then
  `403`. Every console page requires Basic auth, the Host header must match
  `I2PD_CONSOLE_HOSTNAME`, and console commands carry a per-page token.
- **Password leaks.** The password is not in any command line, environment,
  Compose model or `docker inspect` output. It lives in your secret file and
  in a 0600 file on a 1 MiB tmpfs inside the container.
- **Tampered bootstrap data.** Reseed HTTPS does not verify server
  certificates, so `reseed.verify=true` makes SU3 signature checks against
  the image's read-only certificates the integrity check.
- **A compromised i2pd process.** It cannot change its config, reseed
  certificates or tunnel definitions. It cannot write the root filesystem,
  and it has no capabilities, no privilege escalation (`no-new-privileges`)
  and bounded memory, PIDs and CPU.
- **Bandwidth abuse.** Bandwidth class O (256 KB/s), a configurable transit
  share, at most 2,500 transit tunnels, and never floodfill. The class is a
  target, not a hard cap: above it i2pd refuses new transit tunnels, and your
  own traffic is never throttled.

**Not protected against:**

- **Local users and local malware.** Anything that can connect to
  `127.0.0.1` on this host can use the proxy and SAM. On a shared machine,
  that is the trust boundary.
- **Members of the `docker` group.** They are root-equivalent on the host.
- **Anyone who can write `./i2pd`.** They can replace the router identity,
  the address book or the netDb. A compromised i2pd process can do the same,
  and it can read the console password and connect anywhere the container can
  reach.
- **Network observers.** The console is plain HTTP, so on a LAN the Basic
  auth credentials can be read in transit.
- **The limits of I2P itself.** I2P improves privacy but does not guarantee
  anonymity, and it does nothing about browser fingerprinting.
- **Requests with Host `0.0.0.0`.** i2pd also accepts its own listen address
  as a Host. Browsers block web pages from requesting `0.0.0.0` and would not
  attach your saved credentials to it.
- **Old Docker engines.** Docker Engine 28 and later block other hosts from
  routing directly to container addresses. Older engines did not in every
  setup, so keep Docker current.

## Using the router

### Browser

In Firefox (ideally a separate profile), open the network settings and choose
manual proxy configuration:

- HTTP Proxy `127.0.0.1`, port `4444`;
- enable "Also use this proxy for HTTPS".

The proxy only reaches `.i2p` sites. It has no outproxy and replaces your
browser's User-Agent on plain-HTTP requests. HTTPS `.i2p` sites still see it,
because the proxy only tunnels encrypted bytes for them.

### Remote server over SSH

Keep the defaults and forward the ports you need:

```bash
ssh -L 4444:127.0.0.1:4444 -L 7070:127.0.0.1:7070 user@server
```

Then use `127.0.0.1:4444` as the proxy and open <http://127.0.0.1:7070>
locally. The Host header stays `127.0.0.1`, so the console accepts it. Forward
SAM (`-L 7656:127.0.0.1:7656`) only for a local application that needs it.

## LAN and Tailscale access (opt-in)

Read all of this before setting any `*_BIND_IP` variable.

> **Warnings**
>
> - **Never bind `0.0.0.0` or `::`.** That exposes the service on every
>   network the host is on, and the entrypoint refuses to start. Bind exactly
>   one address on the network you trust.
> - **Docker bypasses ufw.** Docker inserts its own iptables rules for
>   published ports ahead of ufw and firewalld rules, so "the firewall blocks
>   it" is not a safeguard. The bind address is.
> - **The HTTP proxy has no authentication.** Every device that can reach it
>   uses I2P as your router.
> - **Basic auth goes over plain HTTP.** Anyone on the path can read the
>   console password. On a LAN, prefer SSH forwarding. Tailscale encrypts the
>   traffic, but every tailnet device that can reach the port can still try
>   passwords.
> - **SAM is roughly shell-level access.** It has no authentication, and
>   `STREAM FORWARD` lets any client make the container open connections to
>   arbitrary hosts and ports it can reach, including other machines on your
>   LAN. Keep `I2PD_SAM_BIND_IP` on `127.0.0.1`. If an application on another
>   machine needs SAM, give it an SSH tunnel.

### LAN

In `.env`:

```dotenv
I2PD_PROXY_BIND_IP=<this-host-lan-ip>
# Optional. The console hostname follows this address automatically.
I2PD_CONSOLE_BIND_IP=<this-host-lan-ip>
```

Then run `docker compose up -d`. Each port is published on exactly one
address, so the console then answers only at `http://<this-host-lan-ip>:7070`
and returns 403 for any other Host. If you also need the proxy or SAM on
`127.0.0.1`, add a second port mapping in a local `compose.override.yml`. The
console accepts exactly one hostname, so it cannot answer on both.

### Tailscale

In `.env`:

```dotenv
I2PD_PROXY_BIND_IP=<this-host-tailscale-ip>
I2PD_CONSOLE_BIND_IP=<this-host-tailscale-ip>
# Only if you open the console by its MagicDNS name instead of the IP:
#I2PD_CONSOLE_HOSTNAME=<magicdns-name>
```

- Restrict which devices may reach ports 4444 and 7070 with Tailscale ACLs.
  The tailnet is your trust boundary.
- The container cannot start until the Tailscale address exists. After a
  reboot, make sure `tailscaled` is up before Docker starts the stack, for
  example with a systemd drop-in giving `docker.service`
  `After=tailscaled.service`.

## Configuration

All settings are optional and have safe defaults. See `.env.example`. The
`*_BIND_IP` variables take IPv4 addresses: the console's Host check does not
handle bracketed IPv6 literals.

| Variable | Default | Meaning |
|---|---|---|
| `I2PD_PROXY_BIND_IP` | `127.0.0.1` | Host address for the HTTP proxy (4444). |
| `I2PD_CONSOLE_BIND_IP` | `127.0.0.1` | Host address for the web console (7070). |
| `I2PD_SAM_BIND_IP` | `127.0.0.1` | Host address for SAM (7656). Keep it on loopback. |
| `I2PD_CONSOLE_HOSTNAME` | `I2PD_CONSOLE_BIND_IP` | The only Host the console accepts (apart from its listen address). |
| `I2PD_HTTP_USER` | `i2pd` | Console username. |
| `I2PD_HTTP_PASS_FILE` | `./secrets/i2pd_http_pass` | Host path of the password file. |
| `I2PD_SHARE` | `50` | Percent of the class O bandwidth offered to transit traffic. `0` disables transit (`--notransit`). |
| `I2PD_DATA_DIR` | `./i2pd` | Router identity and state. Must be owned by `I2PD_USER`. |
| `I2PD_USER` | `100:65533` | uid:gid inside the container. Never 0. |
| `I2PD_MEM_LIMIT` / `I2PD_PIDS_LIMIT` / `I2PD_CPUS` | `512m` / `256` / `1.0` | Resource limits. |
| `I2PD_IMAGE` | pinned in `docker-compose.yml` | Image override. Use a release tag pinned by digest. |

The password file must hold a single line of at least 16 characters, with no
`#` (i2pd treats it as a comment), no leading or trailing whitespace, and not
the old placeholder. The entrypoint refuses anything else and says why.
`openssl rand -base64 32` always qualifies.

Router settings live in `config/i2pd.conf`. i2pd refuses to start on unknown
options. Never put the password there, because the entrypoint appends it.
The console username and hostname and the transit share come from `.env`,
and the bandwidth class from `docker-compose.yml`. They are passed on the
command line, which overrides the file, so setting them in `i2pd.conf` has no
effect.
Options that carry the security settings (`--conf`, `--datadir`,
`--certsdir`, `--tunconf`, `--tunnelsdir`, `--http.pass`, `--http.auth`,
`--http.strictheaders`, `--reseed.verify`) cannot be passed on the command
line.

Client and server tunnels go in `config/tunnels.conf` or
`config/tunnels.d/*.conf` on the host. Both are ignored by git and mounted
read-only, and i2pd ignores tunnel files in the data directory. Any key files
your tunnels reference are stored in `./i2pd`.

## Updating the i2pd image

The default image is pinned to `purplei2p/i2pd:release-3.0.0` by its
multi-platform index digest. To move to a new release:

1. Read the release notes at <https://github.com/PurpleI2P/i2pd/releases>.
   Look for changed defaults, removed or renamed options, and changes to the
   image layout (`/i2pd_certificates`, `/usr/local/bin/i2pd`, uid 100).
2. Resolve the index digest:

   ```bash
   docker buildx imagetools inspect purplei2p/i2pd:release-<version>
   ```

   Use the top-level `Digest:` of the image index (media type
   `application/vnd.oci.image.index.v1+json`), not a per-platform manifest
   digest. A per-platform digest breaks other architectures.
3. Update the `image:` default in `docker-compose.yml` and the version in
   this section, then run both test suites:

   ```bash
   tests/static-checks.sh
   tests/smoke.sh
   ```

   i2pd exits on unknown options, so a passing smoke test also proves that
   `config/i2pd.conf` still parses.
4. Back up `./i2pd` (at least `router.keys`), then deploy:

   ```bash
   docker compose pull
   docker compose up -d
   docker compose ps
   docker compose logs --tail=50 i2pd
   ```

If you set `I2PD_IMAGE` in `.env`, update or remove it there, otherwise it
overrides the new pin. To roll back, revert the commit (or set `I2PD_IMAGE`
to the previous pinned reference) and run `docker compose up -d`.

## Upgrading from the previous version

The previous version published all three services on one `I2PD_BIND_IP`
(documented as the LAN address), passed the console password on the command
line, and relied on the image's defaults inside a writable data directory.

### Breaking changes

1. **Password file.** The console password moved from `I2PD_HTTP_PASS` in
   `.env` to the file `secrets/i2pd_http_pass` (a Compose secret). The
   stack does not start without that file. `I2PD_HTTP_PASS` is ignored and
   logs a warning. Rotate the password: the old value was visible in `ps`,
   `docker inspect` and `docker compose config`.
2. **`I2PD_BIND_IP` removed.** Every port now binds to `127.0.0.1`. LAN
   clients lose access until you opt in per service with
   `I2PD_PROXY_BIND_IP`, `I2PD_CONSOLE_BIND_IP` or `I2PD_SAM_BIND_IP`. A
   leftover `I2PD_BIND_IP` logs a warning.
3. **Wildcard binds refused.** The entrypoint refuses to start if any service
   is published on `0.0.0.0` or `::`.
4. **New entrypoint and explicit user.** `config/entrypoint.sh` replaces the
   image's entrypoint and runs as `100:65533` (the image's user, now explicit
   and overridable). It refuses uid 0, and it checks that the data directory
   is writable before starting. It also validates the password (single line,
   at least 16 characters, no `#`, no surrounding whitespace, not the
   placeholder).
5. **Read-only config.** `config/` is mounted read-only. `i2pd.conf`,
   `tunnels.conf`, `tunnels.d/` and the `certificates` link inside `./i2pd`
   are now ignored. Move reviewed tunnel definitions to `config/`.
   `config/` must be readable by uid 100.
6. **Router behaviour.**

   | Setting | Before | After |
   |---|---|---|
   | Bandwidth class | picked by i2pd: P (2,048 KB/s) on x86_64 hosts with 4+ cores, O on smaller x86_64 hosts, L on ARM | O (256 KB/s transit target) on every host |
   | Transit share | 100% | 50% (`I2PD_SHARE`) |
   | Transit tunnel limit | 25,000 | 2,500 |
   | Reseed signature check | off | on |
   | SOCKS proxy (inside the container only) | on | off |
   | i2pd version | 2.60.0 | 3.0.0: SSU2 defaults to post-quantum ML-KEM-768 (`ssu2.version` 4), refreshed reseed servers, key files created owner-only |

   Floodfill, UPnP, IPv6, the outproxy and User-Agent forwarding stay off,
   now set explicitly. BOB, I2CP and I2PControl stay disabled.
7. **Console Host check.** The console accepts only Host
   `I2PD_CONSOLE_HOSTNAME`, which defaults to the console bind address. Open
   `http://127.0.0.1:7070` rather than `localhost`.
8. **Healthcheck.** It now also requires a SAM `HELLO` reply. It runs every
   60 seconds with a 120-second start period.
9. **Resource limits.** 512 MiB of memory, 256 PIDs and 1 CPU by default.
10. **No image pin in `.env.example`.** It no longer sets `I2PD_IMAGE`. A
    `.env` copied from the old example keeps you on 2.60.0 forever, so remove
    that line unless you pin on purpose.

### Migration steps

The router identity in `./i2pd` is kept. Run these commands from the
repository directory. For rootless Podman, replace `sudo` with
`podman unshare` and `docker compose` with `podman compose`.

```bash
docker compose down
git pull

# 1. New console password as a file secret (this also rotates it).
mkdir -p secrets
(umask 077 && openssl rand -base64 32 > secrets/i2pd_http_pass)
sudo chgrp 65533 secrets/i2pd_http_pass && chmod 0640 secrets/i2pd_http_pass

# 2. Remove settings that are gone. Keep I2PD_IMAGE only if you pin on purpose.
sed -i -E '/^(I2PD_HTTP_PASS|I2PD_BIND_IP|I2PD_IMAGE)=/d' .env

# 3. Opt back in per service only where needed (never SAM, never 0.0.0.0):
#    echo 'I2PD_PROXY_BIND_IP=<this-host-lan-ip>' >> .env
#    echo 'I2PD_CONSOLE_BIND_IP=<this-host-lan-ip>' >> .env

# 4. Data directory ownership. The router identity stays where it is.
sudo chown -R 100:65533 i2pd
sudo ls -la i2pd   # i2pd.conf, tunnels.conf, tunnels.d and certificates are now ignored
sudo rm -f i2pd/certificates
# The old image created router.keys world-readable (0644); make old files private.
sudo find i2pd -mindepth 1 ! -name .gitkeep -exec chmod go-rwx {} +
# A workaround for the old crash may have made the directory itself writable
# by everyone, which would let any local user swap the router identity.
sudo chmod go-w i2pd

# 5. Config readable by the container user.
chmod -R a+rX config

# 6. Start and verify.
docker compose up -d
docker compose ps
docker compose logs --tail=30 i2pd     # expect no "WARNING" lines from the entrypoint
docker compose config | grep -cFf secrets/i2pd_http_pass   # prints 0
ss -ltn | grep -E ':(4444|7070|7656)\b'   # 127.0.0.1, or the address you opted into
```

If you had custom tunnels in `./i2pd/tunnels.conf` or `./i2pd/tunnels.d/`,
review them and copy them to `config/tunnels.conf` or `config/tunnels.d/`.
Then run `chmod -R a+rX config` again.

## Tests

Both suites run in CI and locally:

- `tests/static-checks.sh` renders the Compose model and checks loopback
  defaults, per-service opt-in, that no secret appears in the command or
  environment, read-only mounts, container hardening, the digest pin, workflow
  actions pinned to commit SHAs, and that no private or Tailscale addresses or
  personal paths are committed.
- `tests/smoke.sh` starts the real image with `network_mode: none` and checks
  the console (401 without credentials, 200 with the password, 403 for a
  foreign Host), closed extra ports, that the password is absent from
  `/proc/1/cmdline`, `/proc/1/environ` and `docker inspect`, the read-only
  root filesystem, reseed signature verification (with a forged SU3 file), and
  every entrypoint refusal.

The smoke test uses its own Compose project and temporary directories. It
never touches a running deployment, `./i2pd`, `./secrets` or `.env`.

## Source safety

- `.env`, `secrets/`, local Compose overrides and `config/tunnels*` are
  ignored by git and by `.dockerignore`.
- `i2pd/` is ignored except for `.gitkeep`: router keys, `router.info`, the
  address book, netDb, peer profiles and destinations never enter git.
- `docker compose config` no longer contains the password, but it does show
  absolute paths and any opt-in addresses. Review it before sharing.

## License

MIT

## References

- i2pd configuration: <https://i2pd.readthedocs.io/en/latest/user-guide/configuration/>
- i2pd releases: <https://github.com/PurpleI2P/i2pd/releases>
- i2pd Docker image: <https://hub.docker.com/r/purplei2p/i2pd>
- SAM v3 protocol: <https://geti2p.net/en/docs/api/samv3>
