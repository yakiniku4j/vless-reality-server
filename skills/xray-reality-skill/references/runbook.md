# Runbook: Xray REALITY server (VLESS)

Operational detail behind `vless-reality-server.sh`. Read this before concluding anything is
broken.

## Access model

Two things are deliberately not automated.

**SSH keys.** The tool never reads, generates, copies or uploads key material, and
never writes `authorized_keys`. The operator establishes the login; `vless-reality-server.sh
check` only verifies that it works without prompting. `BatchMode=yes` means a
password-only host cannot be used at all — the fix is for the operator to set up key
or agent based login first, and the tool prints exactly how when it detects the
situation. Host keys are not auto-accepted either: the operator connects once and
verifies the fingerprint.

**Server-side configuration.** Every file under `<deploy-dir>` is written by
`ctl.sh`. The local driver does three things over SSH: create the directory, copy
`ctl.sh` into it, and run it. If something on the server needs to change, the change
belongs in a `ctl.sh` subcommand, not in an ad-hoc command typed over SSH. This keeps
one reviewable place where the server's state is defined.

## How the deployment is wired

- **Official image**, `ghcr.io/xtls/xray-core:latest`, run through Docker Compose.
- **Restart policy** `unless-stopped`, and Docker itself is enabled at boot. A reboot
  brings the node back with no intervention.
- **One inbound**: VLESS, TCP, REALITY, `xtls-rprx-vision`, listening on `0.0.0.0:<port>`.
- **Two outbounds**: `freedom` (direct) and `blackhole`. No routing rules, so the
  server forwards everything and does not leak anything.
- **Log level** `warning`: enough to see connections, quiet enough to keep the disk
  and the fingerprint small.
- **Log rotation** 10 MB × 3 files via the json-file driver.

### About the image running as non-root

`ghcr.io/xtls/xray-core` is distroless and runs as **UID 65532**. That has a direct
consequence: anything the container must read — in practice `config.json`, which
holds the REALITY private key — has to be readable by that uid.

The deploy handles this by `chown`ing `config.json` to the image's declared user and
keeping it `600`, rather than making it world-readable. `ctl.sh` re-applies this
after every rewrite of the config. The image's user is recorded in `.imguser`.

If you ever see `open /etc/xray/config.json: permission denied` in the container log,
that ownership was lost — fix it with:

```sh
ssh <host> "chown \$(cat <deploy-dir>/.imguser) <deploy-dir>/config.json && cd <deploy-dir> && docker compose restart"
```

## Diagnosing

Work outward, and stop as soon as a layer fails.

1. `vless-reality-server.sh status` — is the container up? Is the port listening? Is the restart
   policy `unless-stopped`?
2. `vless-reality-server.sh logs 50` — Xray's own view. `started` with no errors is good.
3. `vless-reality-server.sh doctor` — config validity, container, TLS probe, outbound.
4. `vless-reality-server.sh info` — re-read the parameters and rebuild the link.
5. Client side — the link must match the live config exactly.

### The two false alarms

**A local VPN or proxy is in the path.** If the machine you run `doctor` from has a
full-tunnel VPN active (Shadowrocket, a corporate VPN, Tailscale exit node), every
outbound check goes through it first. Non-standard ports in particular get mangled,
producing "tls handshake failed" for a server that is perfectly healthy. `doctor`
detects a `utun` default route and warns. Turn the tunnel off and re-check before
believing a negative result.

**The container cannot read the config.** See the distroless note above. It shows up
as the container exiting immediately or as a permission error in the log, while
`docker compose` itself reports success.

### Useful one-liners

```sh
# What the server presents on its own port (the REALITY masquerade):
ssh <host> "echo | openssl s_client -connect 127.0.0.1:<port> -servername <sni> -tls1_3 2>/dev/null | openssl x509 -noout -subject -issuer"

# Can the server reach the internet at all:
ssh <host> "curl -sI -m 10 https://www.google.com | head -1"

# Confirm the config parses, without touching the running container:
ssh <host> "docker run --rm -v <deploy-dir>/config.json:/etc/xray/config.json:ro ghcr.io/xtls/xray-core:latest run -test -config /etc/xray/config.json"

# Live connections (shows client emails):
ssh <host> "docker logs --tail 50 <container>"
```

## Common client-side failures

| Symptom | Cause |
| --- | --- |
| Connects then stalls, or times out | Port not reachable: host firewall **and** cloud security group must both allow it |
| `REALITY: received real certificate (potential MITM or redirection)` **in the client log** | The client's public key, short id, SNI or UUID does not match the server — or the client's traffic is itself going through another tunnel, so the handshake reaches Xray second-hand |
| Works, then breaks after a key rotation | Every client must be updated with the new public key |
| Works for one user, not another | That user's UUID was removed or mistyped |

## Changing things

### Add or remove users

`client-add <name>` appends a client with a fresh UUID and the same flow, then
restarts. `client-rm <name>` removes by email (or UUID). The last client cannot be
removed — the config would be invalid.

### Rotate the REALITY key pair

```sh
vless-reality-server.sh rotate-keys
```

Use when the private key may have leaked. The private key is replaced and the new
public key printed. **Every client breaks until it is updated** with the new
`pbk`. Prefer adding a user over rotating keys for ordinary membership changes.

### Change the masquerade target

```sh
vless-reality-server.sh set-sni www.microsoft.com
```

`dest` and `serverNames` are updated together. The new domain must serve TLS 1.3 and
HTTP/2. Verify with:

```sh
openssl s_client -connect www.microsoft.com:443 -servername www.microsoft.com -tls1_3 </dev/null 2>/dev/null | grep "Protocol\|ALPN"
```

### Change the port

```sh
vless-reality-server.sh set-port 8443
```

This updates the config and the compose mapping and opens ufw. It does **not** touch
the cloud provider's security group, and it does not close the old port in ufw. Do
both by hand.

### Update Xray

```sh
vless-reality-server.sh update
```

Pulls the latest image and recreates the container. Config format has been stable
across recent majors, but read the release notes if the node has not been updated in
a long time, and run `backup` before jumping versions.

## Backups

The one irreplaceable value is the **REALITY private key**. The public key is
derived from it, not the other way round, so losing the private key means every
client has to be reconfigured. Losing only UUIDs is harmless — `client-add` issues
new ones.

That key lives in exactly one place, `<deploy-dir>/config.json`. It is deliberately
not duplicated into a side file, because a side file goes stale the moment the key
is rotated or the port changes, and a stale copy of a secret is worse than none.

**This skill will not export that key, on purpose.** No subcommand reads it out of
`config.json` or prints it, and the local driver redacts anything resembling a key
before displaying it. An agent driving this tool therefore cannot surface it — not by
`info`, not by `doctor`, not by `backup`. Do not try to get around that with
`ssh <host> cat <deploy-dir>/config.json`; that defeats the whole arrangement.

What the tool *will* export is the non-secret half:

```sh
vless-reality-server.sh backup ./node-details-$(date +%F).md    # or omit the path to print it
```

That gives port, masquerade domain, short ids, the public key and the client UUIDs —
everything needed to configure clients, and nothing that is dangerous to hold.

To back up the private key, do it yourself, directly on the host:

```sh
scp <host>:<deploy-dir>/config.json ./config.json.$(date +%F).backup
```

Treat that copy as a secret: mode 600, never in version control, never on a client
machine. Do this before `rotate-keys` if the old key must be retained.

A consequence worth knowing: if `public.key` is ever lost, `info` and `backup` cannot
show the public key, because deriving it would mean reading the private key. That is
by design, not a bug. Restore the file from any working client's `pbk=` value.

An older deployment may still have a `vps-key.md` written by an earlier version.
Nothing maintains it — delete it once you have a fresh `backup`, so it cannot
mislead you later.

## Removing the deployment

```sh
vless-reality-server.sh uninstall --yes     # stops and removes the container
ssh <host> "rm -rf <deploy-dir>"   # delete the files when you are sure
```

Also remove the firewall rule you added for the port.
