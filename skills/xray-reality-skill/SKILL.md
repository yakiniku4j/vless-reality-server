---
name: xray-reality-skill
description: Deploy and operate an Xray REALITY server (VLESS protocol) on a VPS over SSH - generate keys, write the config, run it in Docker with auto-restart, add or remove clients, rotate keys, change port or masquerade domain, and verify the deployment. Use when setting up a proxy server, standing up a VPS node, managing users on one, or troubleshooting a REALITY deployment.
license: MIT
compatibility: >-
  Local driver: bash 3.2+, ssh, scp, curl and python3, on macOS, Linux, WSL or
  Git Bash on Windows. Windows without WSL needs Git for Windows, because the
  driver is a bash script. Server: Ubuntu or Debian with Docker (installed
  automatically) and python3, reached over SSH with key-based authentication.
metadata:
  version: "1.0.0"
  author: see the repository README
---

# Xray REALITY Server

Deploys and maintains a VLESS-REALITY node on a remote host. The stack is the
official `ghcr.io/xtls/xray-core` image run by Docker Compose with
`restart: unless-stopped`, so it survives a reboot or a crash.

The skill holds **no server address, domain or secret**. Everything is supplied by
whoever runs it and kept outside the skill directory.

## Three rules this skill follows

**It never touches SSH key material.** It does not read, generate, copy or upload
private keys, and it does not write to the server's `authorized_keys`. Establishing
the SSH connection is the operator's job. This tool only *checks* that a
non-interactive login already works, and guides the operator if it does not.

**All server-side configuration goes through one script.** The driver copies
`assets/ctl.sh` to the target and invokes it. Every file on the server —
`config.json`, `docker-compose.yml`, `public.key`, the client list — is created and
modified by `ctl.sh` alone. The driver never writes configuration over SSH by hand.

**The REALITY private key is never read out of `config.json`, printed, or transmitted.**
No subcommand exposes it — `info`, `doctor`, `status` and `backup` all exclude it, and
the driver redacts anything that looks like a key before it is displayed. Do not work
around this by running `ssh <host> cat <deploy-dir>/config.json`, or by adding a
command that dumps it. The key is the one value that cannot be regenerated (the public
key derives from it, not the reverse), so it stays on the host and nowhere else.
Backing it up is a deliberate human action performed directly on the host, outside
this tool.

## Before anything: an SSH login that works without prompting

An agent cannot type a password, and this tool runs with `BatchMode=yes`, so a
password-only host **cannot work**. Determine which kind the host is before
planning anything, and confirm it with the operator rather than assuming.

```sh
scripts/vless-reality-server.sh check -H <ssh-host-or-alias>
```

`check` reports one of:

| Result | Meaning |
| --- | --- |
| key-based login works | Good to go |
| `server is password-only` | Stop. Print the guide below; do not attempt the deploy |
| `the key offered was not accepted` | The operator must select/load the right key |
| `host key is not trusted yet` | The operator must connect once and verify the fingerprint |
| `could not connect` | Name, port or network path is wrong |

For a password-only host, the way forward is to **set up key-based login first**,
as a separate step the operator performs by hand:

```sh
ssh-keygen -t ed25519 -C "xray-reality-skill"      # if there is no key yet
ssh-copy-id -p <port> <user>@<host>          # the operator types the password once
ssh -p <port> <user>@<host> true             # confirm nothing is asked
ssh-add --apple-use-keychain ~/.ssh/id_ed25519   # if the key has a passphrase
```

The tool prints this guidance itself; it does not carry it out. `--auth password`
declares the situation explicitly and stops with the same guidance. `--auth key`
asserts the expectation without changing what is checked.

## What a user must provide

1. **An SSH target with a working key-based (or agent-based) login.** `root` is
   assumed unless `--user` is given. Docker is installed automatically on the host.
2. **A masquerade domain** — the site REALITY borrows its TLS certificate from.
   It must serve **TLS 1.3 and HTTP/2**, be popular enough to be unremarkable, and
   not be one of the operator's own domains. Good picks: `www.tesla.com`,
   `www.microsoft.com`, `www.apple.com`.

Everything else — UUID, REALITY key pair, short id, ports, config — is generated.

## Quick start

```sh
scripts/vless-reality-server.sh check -H <ssh-host-or-alias>
scripts/vless-reality-server.sh install -H <ssh-host-or-alias> --sni www.tesla.com
scripts/vless-reality-server.sh doctor          # verify server-side and from here
scripts/vless-reality-server.sh link            # the vless:// link for clients
scripts/vless-reality-server.sh qr              # QR code for a phone client
```

`install` prints the client share link when it finishes. The target and client
details are then remembered, so later commands need no flags.

`--label "<text>"` sets the name the client shows for the node, and defaults to
`self-hosted-vless-node`. **Ask the user once, before deploying, whether they want a
different name**, and pass it as `--label` if they do. A phone full of nodes all
called the same thing is useless, and only the user knows what they will recognise.
Ask once, then move on.

### Tell the user how to confirm it works

`doctor` proves the node is healthy from here, but the only test that counts is the
user's own device. `link` and `qr` print this reminder themselves, and the agent
should repeat it:

> Connect on your device, then open <https://ipdata.co>. The IP it shows should be
> the server's, not your own. If it still shows your own address, the client is not
> routing through the node yet.

Say the expected address explicitly — it is the fastest way for the user to tell
"connected" from "silently not connected".

## Commands

| Command | Effect |
| --- | --- |
| `check` | Report reachability and whether the login is key-based |
| `install` | Deploy: generates secrets, writes config, starts the container |
| `status` | Container state, listening port, restart policy, Docker-at-boot |
| `doctor` | Config validity, container, TLS probe, outbound; then checks from here |
| `info` | Read the live parameters back off the server and refresh the local link |
| `backup [file]` | Export the client-facing details (public key, UUIDs, port, SNI). Never the private key |
| `link` / `qr [file]` | The client share link / a QR rendering of it |
| `logs [n]` | Tail the container log |
| `restart` / `up` / `down` / `update` | Compose lifecycle; `update` pulls a newer image |
| `client-add <name>` / `client-rm <name>` / `client-list` | Manage users (each gets its own UUID) |
| `rotate-keys` | New REALITY key pair — **all clients must update their public key** |
| `set-port <n>` / `set-sni <domain>` | Change the listening port / masquerade target |
| `shell` / `config` | SSH into the host / print the stored target |
| `uninstall --yes` | Stop and remove the container, keeping the files |

Options: `-H --host`, `-U --user`, `-P --ssh-port`, `--auth key|password`,
`--name`, `--listen`, `--sni`, `--dir`, `--addr`, `--label`, `--force`. Run with
`--help`.

## Scope

- VLESS over **TCP** with **REALITY** and `xtls-rprx-vision`. Not WebSocket, gRPC,
  TLS-passthrough, or multi-protocol setups.
- One node per host by default; `--name` and `--dir` allow a second one alongside.
- `install` refuses to overwrite a live deployment unless `--force` is given. That
  refusal is protection, not a bug — use `client-add` / `set-*` / `update` instead.

## Layout

```
<skill>/                       shareable, contains no secrets
├── scripts/vless-reality-server.sh     local driver: check, copy ctl.sh, invoke it
├── assets/ctl.sh              copied to <deploy-dir>/ctl.sh; owns all server configuration
└── assets/gen_qr.py           local QR renderer

<deploy-dir>/                  on the server, default /root/xray
├── config.json                mode 600, owned by the image's non-root user
├── docker-compose.yml
├── ctl.sh                     the only thing that writes here
└── public.key                 the client-side public key (not secret)

~/.local/share/vless-reality-server/   local state, VRS_HOME overrides
├── target.env                 ssh target, name, port, masquerade domain
├── <name>.env / <name>.link   client-side parameters and the share link
└── <name>-qr.png
```

The REALITY private key is written to exactly one place, `config.json` on the
server. It is not duplicated into a second file that would silently go stale after
a key rotation, port change or user change. When a copy is actually wanted, export
one deliberately with `backup`.

## Rules for operating it

- Run `check` before `install`, and never plan a deploy on a host whose login has
  not been confirmed as key-based.
- **Never run `install` against a live deployment** without `--force`.
- `rotate-keys` invalidates every existing client. Say so before running it. If the
  old key must be kept, the operator copies `config.json` off the host themselves
  first; this skill provides no way to export it.
- Changing the port changes the firewall *and* the cloud security group. `set-port`
  only handles ufw.
- `client-add`, `client-rm`, `rotate-keys`, `set-port` and `set-sni` restart the
  container, dropping live connections for a moment. Batch changes.
- Before concluding the server is broken, read `references/runbook.md` — the two
  most common false alarms are a stacked local VPN and the distroless file
  permissions.
