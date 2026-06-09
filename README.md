# I2P Router Docker Compose

This project runs an i2pd router with an HTTP proxy, web console, and SAM
endpoint through Docker Compose. It is intended for local `.i2p` browsing and
local I2P-aware clients. It is not an I2P hidden service and it should not be
published as an open internet proxy.

## Quick Start

Create a private local environment file before starting:

```bash
test -f .env || cp .env.example .env
LAN_IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
sed -i "s|^I2PD_BIND_IP=.*|I2PD_BIND_IP=${LAN_IP}|" .env
sed -i "s|replace-with-a-long-random-password|$(openssl rand -base64 32)|" .env
docker compose up -d
docker compose ps
```

The services bind to `I2PD_BIND_IP`, which should be this host's LAN address:

- Web console: `http://<server-lan-ip>:7070`
- HTTP proxy: `<server-lan-ip>:4444`
- SAM bridge: `<server-lan-ip>:7656`

The web console uses HTTP basic auth. The username and password come from
`I2PD_HTTP_USER` and `I2PD_HTTP_PASS` in your ignored `.env` file.

Give the router a few minutes after first startup to bootstrap into the I2P
network before expecting `.i2p` sites to load reliably.

## Browser Proxy

In Firefox network proxy settings, choose manual proxy configuration:

- HTTP Proxy: `127.0.0.1`
- Port: `4444`
- Enable `Use this proxy for HTTPS too` if Firefox shows that option.

This proxy is mainly for `.i2p` sites, not normal clearnet browsing.

## LAN Or Remote Use

For LAN access, set this value in `.env`:

```dotenv
I2PD_BIND_IP=<server-lan-ip>
```

Only do this on a trusted LAN. Do not bind to `0.0.0.0`.

For remote servers, leave the Compose bindings on `127.0.0.1` and use SSH
forwarding instead of internet-facing port publishing:

```bash
ssh -L 4444:127.0.0.1:4444 -L 7070:127.0.0.1:7070 -L 7656:127.0.0.1:7656 user@server
```

Then configure your local browser to use `127.0.0.1:4444` and open the console
at `http://127.0.0.1:7070` through the tunnel.

## Source Safety

The repository is prepared so public source does not include local secrets or
generated I2P identity data:

- `.env` is ignored and should contain the real console password.
- `i2pd/` is ignored except for `.gitkeep`.
- Router keys, `router.info`, addressbook data, netDb, peer profiles,
  destinations, pid files, and local config stay out of git.
- `.dockerignore` excludes the same runtime and secret files from Docker build
  contexts.
- Do not publish `docker compose config` output from a machine with a real
  `.env`; Compose expands the password into the rendered command.

Before publishing, initialize git if needed and run a local check:

```bash
git init
git check-ignore --no-index .env i2pd/router.keys i2pd/router.info i2pd/i2pd.conf
rg -n "192\\.168\\.|10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\." \
  --hidden -g '!i2pd/**' -g '!.env' .
```

## Security Notes

- Do not expose `4444`, `7070`, or `7656` directly to the public internet.
- The HTTP proxy can be abused if reachable by untrusted clients.
- The web console is password protected, but host binding is still the primary
  safety boundary.
- The i2pd process listens on `0.0.0.0` inside the container so Docker can
  publish the ports; host exposure is controlled by `docker-compose.yml`.
- I2P improves privacy, but it does not guarantee full anonymity.

## License

MIT

## References

- i2pd configuration: https://i2pd.readthedocs.io/en/latest/user-guide/configuration/
- i2pd Docker image: https://hub.docker.com/r/purplei2p/i2pd
