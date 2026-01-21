# xray-reality-skill

**Agent Skill for deploying an Xray REALITY node (VLESS)**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) ![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20WSL-blue) ![Agent Skill](https://img.shields.io/badge/Agent%20Skill-format-blueviolet)

> **中文版**: [README.zh.md](README.zh.md)

## Installation

The skill follows the open Agent Skills format, so one directory works across tools.
Pick whichever route matches how you work.

### Option 1 — the skills CLI, one command

The [skills CLI](https://github.com/vercel-labs/skills) detects which agents you have
installed and drops the skill into each one's directory:

```sh
npx skills add yakiniku4j/xray-reality-skill
```

It installs per project by default; add `-g` for a user-wide install. Prefer this if
you want one command to cover every agent on your machine.

### Option 2 — Claude Code, via the plugin marketplace

```
/plugin marketplace add yakiniku4j/xray-reality-skill
/plugin install xray-reality-skill@xray-reality-skill
```

### Option 3 — copy the directory

```sh
git clone https://github.com/yakiniku4j/xray-reality-skill vrs
cp -r vrs/skills/xray-reality-skill ~/.codex/skills/ && rm -rf vrs
```

However you install it, **open a new session afterwards**. Agents load skills at
startup, so one that is already running will not see it.

## Overview

An Agent Skill that deploys and operates an Xray REALITY node (VLESS) on a VPS over SSH.
Hand it two things — an SSH target and a masquerade domain — and it generates the
REALITY key pair, writes the Xray configuration, and runs the official `xray-core`
image under Docker with `restart: unless-stopped`. It hands back a `vless://` link
and a QR code.

Afterwards it keeps operating the node: add and remove users, rotate keys, change the
port, switch the masquerade target, update the image, and check that the deployment
actually works from both ends.

There is no panel, no database and no web interface. The node is one container, one
configuration file, and a share link, managed from the command line by an agent.

## Features

- 🚀 **Two inputs, everything else generated** — UUID, REALITY key pair, short id, config and ports
- 🎭 **REALITY, no domain or certificate** — borrows a real site's TLS 1.3 + HTTP/2 handshake
- 🐳 **Official image under Docker** — `restart: unless-stopped`, so a reboot brings the node back
- 👥 **Per-user clients** — `client-add` / `client-rm` / `client-list`, each user gets their own UUID
- 🔑 **Key rotation** — replace the REALITY key pair on demand
- 🔌 **Port and masquerade changes** — `set-port`, `set-sni`, with the compose file rebuilt to match
- 🔗 **Share link and QR** — `vless://` URI plus a PNG or terminal QR code, no separate tool
- ✅ **Verification built in** — `check` before deploying, `doctor` after; both ends of the connection
- 🧭 **Password-only hosts handled** — detects them and explains how to switch to key auth instead of failing obscurely
- 🛡️ **The REALITY private key is never readable by the agent** — no command reads or prints it
- 🔒 **SSH keys are never touched** — no key generation, no `authorized_keys` writes, no auto-accepted host keys
- 📄 **One script owns the server** — every file on the host is written by `ctl.sh`, never by ad-hoc commands
- 🌍 **Cross-agent** — one directory, works with Claude Code, Codex, OpenCode and anything else on the standard

## Workflow

```
Given: an SSH target with key-based login + a masquerade domain
  |
  +-- check        confirm the login works without a password prompt
  |
  +-- install      generate UUID, REALITY key pair, short id
  |                write config.json and docker-compose.yml
  |                start the container (installs Docker on the host if absent)
  |
  +-- doctor       server side: config, container, TLS probe, outbound
  |                your side:  reachability and handshake
  |
  +-- link / qr    the client share link, and a QR code for it
  |
  +-- operate      client-add / client-rm / rotate-keys / set-port / set-sni
  |                logs / restart / update / backup
  |
  +-- Done: a running node and a link that works
```

## Usage

Once installed, just say what you want:

- *"Set up a VLESS-REALITY node on my VPS at 203.0.113.10"*
- *"Add a user called laptop to my node"*
- *"Rotate the REALITY keys on that server"*
- *"Move the node to port 8443"*
- *"Is my node still working?"*

The skill activates on its own when the request matches, and does the work over SSH.

To drive it yourself, run the script from the skill directory:

```sh
cd skills/xray-reality-skill

./scripts/vless-reality-server.sh check   -H myvps
./scripts/vless-reality-server.sh install -H myvps --sni www.tesla.com
./scripts/vless-reality-server.sh doctor
./scripts/vless-reality-server.sh link
```

`--sni` is the masquerade domain REALITY borrows its TLS certificate from. It must
serve TLS 1.3 and HTTP/2, be busy enough to be unremarkable, and not be a domain you
own. `www.tesla.com`, `www.microsoft.com` and `www.apple.com` all work.

Run any command with `--help` for the full option list.

## Requirements

**Where the agent runs**

- `bash` 3.2 or newer, plus `ssh`, `scp` and `curl`
- `python3` (only for rendering QR codes; optional otherwise)
- macOS, Linux, WSL, or Windows with Git for Windows. There is no PowerShell port:
  native Windows without Git Bash cannot run the driver.

**The server**

- Ubuntu or Debian, reached as root over SSH
- Docker (installed automatically if absent) and `python3`
- A reachable public IP

## Security model

Three properties are built in, not bolted on:

- **The REALITY private key is never read out, printed, or transmitted.** No
  subcommand exposes it, and the driver redacts anything resembling a key before
  display. Backing it up is a deliberate action you perform on the host by copying
  `config.json`; the tool provides no way to export it. This exists so an agent can
  never surface the one value that cannot be regenerated.
- **Your SSH keys are never touched.** The skill does not read, generate, copy or
  upload key material, does not write `authorized_keys`, and does not auto-accept
  host keys. Establishing the connection is your job; the skill only verifies it.
- **No secrets live in this repository.** The generated key pair exists only on the
  server. Client-side details are written locally under `~/.local/share/`.

## Scope

- VLESS over TCP with REALITY and `xtls-rprx-vision`. Not WebSocket, gRPC,
  TLS-passthrough or multi-protocol setups.
- One node per host by default; `--name` and `--dir` allow a second alongside.
- `install` refuses to overwrite a live deployment without `--force`.

## License

MIT — see [LICENSE](LICENSE) for details.

You are responsible for complying with the laws that apply where you deploy this.

## Credits

Built on top of:

- [Xray-core](https://github.com/XTLS/Xray-core) — the proxy engine behind VLESS, REALITY and Vision

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Make your changes
4. Submit a pull request
