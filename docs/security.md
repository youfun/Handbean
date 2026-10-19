# Deployment security

Handbean can read and modify workspace files and execute tools. Treat its web
endpoint as an administrative interface, not as a public application.

## Access modes

`HANDBEAN_ACCESS_MODE` is an explicit deployment choice:

* `local` (the default on loopback) preserves desktop/native-host operation.
  It performs no password authentication, but accepts only a loopback network
  peer, a loopback `Host`, and (when present) a same-origin `Origin`. It is safe
  only when the listener is loopback-bound and not reachable through a proxy.
* `password` protects HTTP routes, controllers, LiveView WebSocket, and
  LiveView long-poll connections with single-user HTTP Basic authentication.
  Set `HANDBEAN_ACCESS_USERNAME` (default `handbean`) and a long random
  `HANDBEAN_ACCESS_PASSWORD`.

Example:

```sh
HANDBEAN_ACCESS_MODE=password \
HANDBEAN_ACCESS_USERNAME=handbean \
HANDBEAN_ACCESS_PASSWORD="$(openssl rand -base64 32)" \
PHX_SERVER=true bin/handbean start
```

`HANDBEAN_PUBLIC_BIND=1` binds to `0.0.0.0`, therefore Handbean automatically defaults to
`password` mode and refuses to start without a password. A non-loopback bind
cannot be combined with `local` mode.

## Trusted-LAN HTTP

The Unix launcher `start.sh --lan HOST` and Windows launcher
`start.bat -LanHost HOST` set `PHX_HOST`, `HANDBEAN_PUBLIC_BIND=1`,
`HANDBEAN_ACCESS_MODE=password`, and `HANDBEAN_ALLOW_HTTP=1`. They prompt for a
password unless `HANDBEAN_ACCESS_PASSWORD` is already supplied by the host.
Credentials are not written to disk. The host must be the address other devices
use; the scripts do not guess which network interface is trusted.

`HANDBEAN_ALLOW_HTTP=1` explicitly disables the HTTPS redirect/HSTS for this
instance and advertises HTTP on `PORT`. It does not disable authentication or
origin checking, and `HANDBEAN_PUBLIC_BIND=1` alone does not enable HTTP.
Only use this opt-in on a trusted network: Basic credentials and session traffic
are readable by anyone who can observe unencrypted traffic. Browser-cached HSTS
may still force HTTPS. For Internet-facing deployments, leave this setting unset
and terminate TLS at a reverse proxy.

## Reverse proxies and TLS

Set `HANDBEAN_ACCESS_MODE=password` explicitly when a reverse proxy exposes a
loopback-bound Handbean. Handbean deliberately does **not** trust
`X-Forwarded-For`, `Forwarded`, or similar headers to decide that a request is
local; those headers can be forged unless a separately configured proxy trust
boundary validates them. The listener being loopback-bound does not make a
proxied request local. Because the actual peer of such a request is the local
proxy, a proxy that lets clients forge a loopback `Host` can make `local` mode
appear local; configuring the proxy trust boundary remains the operator's
responsibility, and password mode is required for every proxy deployment.

Terminate TLS at the proxy (or configure HTTPS at the endpoint). Basic
credentials are only transport-safe over TLS. Preserve the `Host`, `Origin`,
and WebSocket upgrade headers. Handbean does not trust `X-Forwarded-Proto`, so
a direct client cannot forge HTTPS and bypass the redirect. A reverse proxy must
reach Handbean over HTTPS or through a same-host loopback connection; do not expose
the backend listener to untrusted clients. Phoenix origin checking remains enabled;
set `PHX_HOST` to the externally visible host. Do not expose development mode:
debug pages and code reload facilities are intended for a trusted machine.

Basic authentication is handled on the initial HTTP request. Phoenix does not
include `Authorization` in socket `:x_headers` (that connect-info field contains
only `x-*` headers), so WebSocket, long-poll, and the development live-reload
socket authenticate with the signed browser session established by that HTTP
request. Changing the configured username or password invalidates existing
authenticated sessions. Development reload is protected by the same access
mode, but debug pages and code reloading should still never be exposed.

Use a unique `SECRET_KEY_BASE`; it signs the browser session and keys its
credential-version marker. Rotate it if it may have leaked.

## HTTP client dependency

Mint is locked to 1.10.1. Its release changelog identifies CVE-2026-82672
(GHSA-rj5m-69wp-cxq9) as fixed by validating HTTP/1 chunk extensions.
Handbean's Req/Finch-backed outbound clients consume provider and other HTTP
responses, so treating this client-side advisory as irrelevant merely because
the workbench is local would be incorrect. The reported response-smuggling
condition involves a malicious upstream and a stricter intermediary framing a
shared HTTP/1 connection differently. Actual exploitability depends on protocol,
upstream and proxy topology; no deployed exploit was reproduced here.

After the upgrade, `mix hex.audit` reports no retired or advisory packages.
