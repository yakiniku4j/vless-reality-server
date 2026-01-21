#!/usr/bin/env bash
# ctl.sh - server-side deploy and control for a VLESS-REALITY node.
#
# This script is the ONLY thing that creates or modifies files on the server.
# The local driver (vless-reality-server.sh) copies it here and then invokes it; it never
# writes configuration over SSH by hand.
#
# Commands:
#   deploy --listen <port> --sni <domain> [--name <label>] [--force]
#   status | info | doctor | backup | logs [n] | restart | up | down | update
#   client-add <name> | client-rm <name> | client-list
#   rotate-keys | set-port <n> | set-sni <domain>
#   help
set -euo pipefail

DIR="${XRAY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONF="$DIR/config.json"
COMPOSE="$DIR/docker-compose.yml"
PUBFILE="$DIR/public.key"
IMGFILE="$DIR/.imguser"
CTRFILE="$DIR/.container"
IMAGE="ghcr.io/xtls/xray-core:latest"
CTR="$(cat "$CTRFILE" 2>/dev/null || echo xray)"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found on the server"; }
py() { python3 "$@"; }

require_config() { [[ -f "$CONF" ]] || die "nothing deployed in $DIR yet"; }

# The image is distroless and runs as a non-root user (usually 65532), so the
# config must be readable by that uid. Keep it 600 and hand it to that user
# instead of making it world-readable.
fix_conf_perms() {
  local u
  u="$(cat "$IMGFILE" 2>/dev/null || true)"
  [[ -n "$u" ]] || u="$(docker inspect "$IMAGE" --format '{{.Config.User}}' 2>/dev/null || true)"
  [[ -n "$u" ]] || u="0"
  chmod 600 "$CONF" 2>/dev/null || true
  chown "$u" "$CONF" 2>/dev/null || chmod 644 "$CONF"
}

json_field() { # json_field <python-expr over `conf`>
  py - "$CONF" "$1" <<'PY'
import json, sys
conf = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"conf": conf}))
PY
}

get_port() { json_field 'conf["inbounds"][0]["port"]'; }
get_sni()  { json_field 'conf["inbounds"][0]["streamSettings"]["realitySettings"]["serverNames"][0]'; }

# The public key is not secret, and it is read ONLY from public.key.
#
# It is deliberately not derived from the private key when public.key is missing:
# that would mean opening config.json's privateKey, which this script must never
# do. A missing public.key is reported, not worked around.
get_pubkey() {
  [[ -s "$PUBFILE" ]] && cat "$PUBFILE"
  return 0
}

render_compose() {
  local port="$1" name="$2"
  printf '%s\n' "$name" > "$CTRFILE"
  CTR="$name"
  cat > "$COMPOSE" <<YAML
services:
  xray:
    image: ${IMAGE}
    container_name: ${name}
    restart: unless-stopped
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    ports:
      - "${port}:${port}"
    command: ["run", "-config", "/etc/xray/config.json"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
}

# ----------------------------------------------------------------- deploy ---
do_deploy() {
  local listen="" sni="" name="xray" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --listen) listen="${2:?--listen needs a value}"; shift 2 ;;
      --sni)    sni="${2:?--sni needs a value}";    shift 2 ;;
      --name)   name="${2:?--name needs a value}";  shift 2 ;;
      --force)  force=1; shift ;;
      *) die "unknown deploy option: $1" ;;
    esac
  done

  [[ "$listen" =~ ^[0-9]+$ ]] || die "deploy requires --listen <port>"
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "deploy --name must be a simple label"
  [[ "$sni" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]+$ ]] || die "deploy requires --sni <domain>"
  if [[ -f "$CONF" && "$force" != "1" ]]; then
    die "already deployed in $DIR (use --force to overwrite, or client-add / set-* to change it)"
  fi

  # Docker is installed here if it is absent, not assumed. A fresh VPS normally
  # has none, and progress goes to stderr so it shows up while it runs.
  if ! command -v docker >/dev/null 2>&1; then
    printf 'docker not found, installing it (this takes a minute) ...\n' >&2
    local dst=/tmp/get-docker.sh
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://get.docker.com -o "$dst" || die "could not download the Docker install script"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$dst" https://get.docker.com || die "could not download the Docker install script"
    else
      die "docker is missing and neither curl nor wget is available to install it"
    fi
    sh "$dst" >/dev/null 2>&1 || die "the Docker install script failed"
    rm -f "$dst"

    # The daemon is often still coming up right after a fresh install, and the
    # error that follows is otherwise a confusing connection failure.
    printf 'waiting for the docker daemon ...\n' >&2
    local i=0
    while ! docker info >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -gt 15 ]; then
        die "the docker daemon is not responding; check it on the host"
      fi
      sleep 2
    done
    printf 'docker is ready\n' >&2
  fi

  if ! docker compose version >/dev/null 2>&1; then
    die "docker is present but the compose plugin is missing; install docker-compose-plugin"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${listen}/tcp" >/dev/null 2>&1 || true
  fi

  mkdir -p "$DIR"

  local uuid x25519 priv pub sid
  uuid="$(docker run --rm "$IMAGE" uuid)"
  x25519="$(docker run --rm "$IMAGE" x25519)"
  priv="$(printf '%s\n' "$x25519" | sed -n 's/^PrivateKey: //p')"
  pub="$(printf '%s\n' "$x25519" | sed -n 's/^Password (PublicKey): //p')"
  sid="$(openssl rand -hex 8)"
  [[ -n "$uuid" && -n "$priv" && -n "$pub" ]] || die "key generation failed"

  umask 077
  cat > "$CONF" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${listen},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${uuid}", "flow": "xtls-rprx-vision", "email": "default" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${sni}:443",
          "xver": 0,
          "serverNames": [ "${sni}" ],
          "privateKey": "${priv}",
          "shortIds": [ "${sid}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": false }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": { "domainStrategy": "AsIs", "rules": [] }
}
JSON

  docker inspect "$IMAGE" --format '{{.Config.User}}' > "$IMGFILE" 2>/dev/null || echo 0 > "$IMGFILE"
  fix_conf_perms

  printf '%s\n' "$pub" > "$PUBFILE"
  chmod 644 "$PUBFILE"

  render_compose "$listen" "$name"

  cd "$DIR"
  local validate
  if ! validate="$(docker run --rm -v "$CONF:/etc/xray/config.json:ro" "$IMAGE" \
                      run -test -config /etc/xray/config.json 2>&1)"; then
    printf 'ERROR: generated config failed validation:\n%s\n' "$validate" >&2
    exit 1
  fi
  local err
  if ! err="$(docker compose up -d 2>&1 >/dev/null)"; then
    printf 'ERROR: docker compose up failed:\n%s\n' "$err" >&2
    exit 1
  fi
  chmod 700 "$DIR/ctl.sh" 2>/dev/null || true

  local addr
  addr="$(curl -s4 -m 10 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$addr" ]] || addr="$(hostname -I 2>/dev/null | awk '{print $1}')"

  echo "---XRAY-INFO---"
  echo "uuid=$uuid"
  echo "publicKey=$pub"
  echo "shortId=$sid"
  echo "port=$listen"
  echo "sni=$sni"
  echo "addr=$addr"
  echo "---XRAY-END---"
}

# ------------------------------------------------------------- inspection ---
do_info() {
  require_config
  local pub; pub="$(get_pubkey)"
  if [[ -z "$pub" ]]; then
    printf 'warning: %s is missing, so the public key is unknown here.\n' "$PUBFILE" >&2
    printf 'warning: this script will not read the private key to derive it.\n' >&2
  fi
  py - "$CONF" "$pub" <<'PY'
import json, sys
conf = json.load(open(sys.argv[1]))
ib = conf["inbounds"][0]
rs = ib["streamSettings"]["realitySettings"]
clients = ib["settings"].get("clients", [])
first = clients[0] if clients else {}
print("port=%s" % ib["port"])
print("dest=%s" % rs.get("dest", ""))
print("serverName=%s" % rs["serverNames"][0])
print("shortIds=%s" % ",".join(rs.get("shortIds", [])))
print("publicKey=%s" % sys.argv[2])
print("flow=%s" % first.get("flow", ""))
print("uuid=%s" % first.get("id", ""))
print("clients=%s" % ",".join(c.get("email", c.get("id", "")) for c in clients))
PY
}

# Exports the deployment's *client-facing* facts so they can be written down
# somewhere safe. It deliberately does NOT include the REALITY private key.
#
# There is no command anywhere in this skill that reads the private key out of
# config.json or prints it. That is on purpose: an agent driving this tool must
# never be able to surface the one value that cannot be regenerated. Backing up
# the private key is a human action performed directly on the host.
do_backup() {
  require_config
  local pub; pub="$(get_pubkey)"
  printf '# VLESS-REALITY deployment - client-facing details\n'
  printf '# Exported %s from %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "$CONF"
  printf '#\n'
  printf '# DELIBERATELY EXCLUDES the REALITY private key. No command in this skill\n'
  printf '# will read or print it. To back up the private key, copy config.json off\n'
  printf '# the host yourself, as the operator, outside this tool:\n'
  printf '#     scp <host>:%s ./config.json.backup\n' "$CONF"
  printf '#\n'
  printf '# Everything below is the non-secret data clients need. It goes stale after\n'
  printf '# rotate-keys / set-port / set-sni / client-*; re-run this then.\n'
  py - "$CONF" "$pub" <<'PY'
import json, sys
conf = json.load(open(sys.argv[1]))
ib = conf["inbounds"][0]
rs = ib["streamSettings"]["realitySettings"]
clients = ib["settings"].get("clients", [])
print()
print("| field | value |")
print("| --- | --- |")
print("| port | %s |" % ib["port"])
print("| masquerade (dest / SNI) | %s |" % rs.get("dest", ""))
print("| serverName | %s |" % rs["serverNames"][0])
print("| shortIds | %s |" % ", ".join(rs.get("shortIds", [])))
print("| REALITY publicKey (give to clients) | %s |" % sys.argv[2])
print("| flow | %s |" % (clients[0].get("flow", "") if clients else ""))
print("| network | %s |" % ib["streamSettings"].get("network", "tcp"))
print()
print("## clients")
print()
for c in clients:
    print("- `%s`  uuid `%s`" % (c.get("email", "?"), c.get("id", "")))
PY
}

do_status() {
  local port; port="$(get_port)"
  log "deploy dir: $DIR"
  if docker ps --filter "name=^/${CTR}$" --format '{{.Names}}' | grep -q "$CTR"; then
    docker ps --filter "name=^/${CTR}$" --format 'container:  {{.Names}}  {{.Status}}  {{.Ports}}'
  else
    log "container:  not running"
  fi
  if command -v ss >/dev/null 2>&1 && ss -tln | grep -q ":${port} "; then
    log "listening:  0.0.0.0:${port}  yes"
  else
    log "listening:  0.0.0.0:${port}  no"
  fi
  log "restart policy: $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CTR" 2>/dev/null || echo n/a)"
  log "docker at boot: $(systemctl is-enabled docker 2>/dev/null || echo unknown)"
}

do_doctor() {
  require_config
  local port sni rc=0
  port="$(get_port)"; sni="$(get_sni)"
  if py -c 'import json,sys;json.load(open(sys.argv[1]))' "$CONF" 2>/dev/null; then
    log "config:      valid JSON"
  else
    log "config:      INVALID"; rc=1
  fi
  if docker ps --filter "name=^/${CTR}$" --format '{{.Names}}' | grep -q "$CTR"; then
    log "container:   running"
  else
    log "container:   NOT running"; rc=1
  fi
  log "tls probe:   ${sni} on 127.0.0.1:${port}"
  local subj
  subj="$(openssl s_client -connect "127.0.0.1:${port}" -servername "$sni" -tls1_3 </dev/null 2>/dev/null \
          | grep '^subject=' | head -1 || true)"
  if [[ -n "$subj" ]]; then
    log "             ${subj#subject=}"
  else
    log "             no handshake"; rc=1
  fi
  if curl -sI -m 10 https://www.google.com >/dev/null 2>&1; then
    log "outbound:    ok"
  else
    log "outbound:    FAILED"; rc=1
  fi
  return $rc
}

do_logs()    { require_config; docker logs --tail "${1:-50}" "$CTR"; }
do_restart() { require_config; cd "$DIR" && docker compose restart; }

# Anything that edits the compose file - a port change, in practice - needs the
# container recreated rather than restarted. `compose restart` keeps the old port
# mapping while the config inside already listens on the new port, so the node
# ends up unreachable: a half-applied change is worse than no change.
do_recreate() { require_config; cd "$DIR" && docker compose up -d; }
do_up()      { require_config; cd "$DIR" && docker compose up -d; }
do_down()    { require_config; cd "$DIR" && docker compose down; }
do_update()  { require_config; cd "$DIR" && docker compose pull && docker compose up -d; }

# ---------------------------------------------------------------- clients ---
do_client_add() {
  [[ -n "${1:-}" ]] || die "usage: ctl.sh client-add <name>"
  require_config
  local name="$1" uuid
  uuid="$(docker run --rm "$IMAGE" uuid)"
  py - "$CONF" "$uuid" "$name" <<'PY'
import json, sys
path, uuid, name = sys.argv[1], sys.argv[2], sys.argv[3]
conf = json.load(open(path))
clients = conf["inbounds"][0]["settings"].setdefault("clients", [])
if any(c.get("email") == name for c in clients):
    sys.exit("error: a client named '%s' already exists" % name)
flow = clients[0].get("flow", "xtls-rprx-vision") if clients else "xtls-rprx-vision"
clients.append({"id": uuid, "flow": flow, "email": name})
json.dump(conf, open(path, "w"), indent=2)
print("added  name=%s  uuid=%s" % (name, uuid))
PY
  fix_conf_perms
  do_restart >/dev/null
  log "restarted"
}

do_client_rm() {
  [[ -n "${1:-}" ]] || die "usage: ctl.sh client-rm <name>"
  require_config
  py - "$CONF" "$1" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
conf = json.load(open(path))
clients = conf["inbounds"][0]["settings"].get("clients", [])
keep = [c for c in clients if c.get("email") != name and c.get("id") != name]
if len(keep) == len(clients):
    sys.exit("error: no client named '%s'" % name)
if not keep:
    sys.exit("error: refusing to remove the last client")
conf["inbounds"][0]["settings"]["clients"] = keep
json.dump(conf, open(path, "w"), indent=2)
print("removed %s" % name)
PY
  fix_conf_perms
  do_restart >/dev/null
  log "restarted"
}

do_client_list() {
  require_config
  py - "$CONF" <<'PY'
import json, sys
conf = json.load(open(sys.argv[1]))
for c in conf["inbounds"][0]["settings"].get("clients", []):
    print("%-20s %s" % (c.get("email", "?"), c.get("id", "")))
PY
}

do_rotate_keys() {
  require_config
  local out priv pub
  out="$(docker run --rm "$IMAGE" x25519)"
  priv="$(printf '%s\n' "$out" | sed -n 's/^PrivateKey: //p')"
  pub="$(printf '%s\n' "$out" | sed -n 's/^Password (PublicKey): //p')"
  [[ -n "$priv" && -n "$pub" ]] || die "could not parse x25519 output"
  py - "$CONF" "$priv" <<'PY'
import json, sys
path, priv = sys.argv[1], sys.argv[2]
conf = json.load(open(path))
conf["inbounds"][0]["streamSettings"]["realitySettings"]["privateKey"] = priv
json.dump(conf, open(path, "w"), indent=2)
PY
  fix_conf_perms
  printf '%s\n' "$pub" > "$PUBFILE"
  chmod 644 "$PUBFILE"
  do_restart >/dev/null
  log "rotated; every client must update its public key"
  log "publicKey=$pub"
}

do_set_port() {
  require_config
  local new="${1:-}"; [[ "$new" =~ ^[0-9]+$ ]] || die "usage: ctl.sh set-port <1-65535>"
  local name; name="$(cat "$CTRFILE" 2>/dev/null || echo xray)"
  py - "$CONF" "$new" <<'PY'
import json, sys
path, new = sys.argv[1], int(sys.argv[2])
conf = json.load(open(path))
conf["inbounds"][0]["port"] = new
json.dump(conf, open(path, "w"), indent=2)
PY
  fix_conf_perms
  render_compose "$new" "$name"
  do_recreate >/dev/null
  log "port set to $new"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${new}/tcp" >/dev/null 2>&1 && log "ufw: allowed ${new}/tcp"
  fi
  log "note: also open ${new}/tcp in the cloud security group"
}

do_set_sni() {
  require_config
  local dom="${1:-}"; [[ "$dom" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]+$ ]] || die "usage: ctl.sh set-sni <domain>"
  py - "$CONF" "$dom" <<'PY'
import json, sys
path, dom = sys.argv[1], sys.argv[2]
conf = json.load(open(path))
rs = conf["inbounds"][0]["streamSettings"]["realitySettings"]
rs["serverNames"] = [dom]
rs["dest"] = "%s:443" % dom
json.dump(conf, open(path, "w"), indent=2)
PY
  fix_conf_perms
  do_restart >/dev/null
  log "masquerade target set to ${dom}:443"
}

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-help}"; shift || true
case "$cmd" in
  deploy)      do_deploy "$@" ;;
  status)      do_status "$@" ;;
  info)        do_info "$@" ;;
  backup)      do_backup "$@" ;;
  doctor)      do_doctor "$@" ;;
  logs)        do_logs "$@" ;;
  restart)     do_restart "$@" ;;
  up)          do_up "$@" ;;
  down)        do_down "$@" ;;
  update)      do_update "$@" ;;
  client-add)  do_client_add "$@" ;;
  client-rm)   do_client_rm "$@" ;;
  client-list) do_client_list "$@" ;;
  rotate-keys) do_rotate_keys "$@" ;;
  set-port)    do_set_port "$@" ;;
  set-sni)     do_set_sni "$@" ;;
  help|"")     usage ;;
  *) die "unknown command: $cmd" ;;
esac
