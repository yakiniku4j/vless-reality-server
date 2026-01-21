#!/usr/bin/env bash
# xray-reality-skill - deploy and operate a VLESS-REALITY node over SSH.
#
# This driver only runs `check`, copies the skill's own ctl.sh to the target, and
# invokes it. Every file on the server is created and modified by ctl.sh, never
# by ad-hoc commands from here.
#
# It never reads, generates, copies or uploads SSH keys, and never edits the
# server's authorized_keys. Connecting is the operator's job; this tool only
# checks that a non-interactive (key-based) login already works.
#
# It also never reads or prints the REALITY private key from config.json. No
# subcommand exposes it, and any output that would contain it is redacted. Do
# not work around that by reading config.json directly.
#
# Usage: vless-reality-server.sh <command> [options]
#
#   check                   verify reachability and how the host authenticates
#   install                 deploy the stack; generates all secrets
#   status | doctor | info  inspect the deployment
#   backup [file]           export client-facing details, never the private key
#   logs [n] | restart | up | down | update
#   client-add <name> | client-rm <name> | client-list
#   rotate-keys | set-port <n> | set-sni <domain>
#   link                    print the client share link
#   qr [file]               render the share link as a QR code
#   shell                   open an SSH session to the server
#   config                  print the stored target
#   uninstall --yes         stop and remove the container (keeps files)
#
# Options (persisted into the target file on `install`):
#   -H --host <ssh-target>   required: a host, or an alias from ~/.ssh/config
#   -U --user <user>         SSH user (default root)
#   -P --ssh-port <port>     SSH port (default 22)
#      --auth <key|password> declare the auth method; password stops with guidance
#      --name <label>        deployment label (default xray)
#      --listen <port>       public TLS port for the proxy (default 443)
#      --sni <domain>        masquerade domain; must serve TLS 1.3 + HTTP/2
#      --dir <path>          remote deploy dir (default /root/xray)
#      --addr <ip-or-host>   address clients dial (default: auto-detected)
#      --label <text>        name clients show for this node (default: "self-hosted-vless-node")
#      --force               overwrite an existing deployment
set -euo pipefail

HOME_DIR="${VRS_HOME:-$HOME/.local/share/vless-reality-server}"
TARGET="$HOME_DIR/target.env"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TGT_HOST="" TGT_USER="root" TGT_SSH_PORT="22" TGT_NAME="xray"
TGT_LISTEN="443" TGT_SNI="" TGT_DIR="/root/xray" TGT_ADDR="" TGT_LABEL=""
DEFAULT_LABEL="self-hosted-vless-node"
FORCE="0" YES="0" AUTH_DECL="" ADDR_EXPLICIT="0"
ARG1="" ARG2=""

# shellcheck source=/dev/null
[[ -f "$TARGET" ]] && . "$TARGET"
# a previous run may have persisted a declared auth mode; it is not sticky
AUTH_DECL=""

log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Last line of defence. Nothing in this skill should ever emit the REALITY
# private key, and no subcommand does. This makes that true even if a future
# command, or a hand-written remote command, returns it: anything that looks
# like the key is stripped before it reaches the screen or the transcript.
redact() {
  sed -E \
    -e 's/("privateKey"[[:space:]]*:[[:space:]]*")[^"]*(")/\1REDACTED\2/g' \
    -e 's/(PrivateKey:[[:space:]]*)[A-Za-z0-9._=\/-]+/\1REDACTED/g' \
    -e '/(privateKey|PrivateKey|PRIVATE KEY)/ s/.*/--- REDACTED: REALITY private key ---/'
}

# Interface carrying the default route, on macOS or Linux. Only used to warn when
# a local VPN or proxy is in the path. BSD route(8) and iproute2 print different
# things, hence the branch.
default_iface() {
  case "$(uname -s)" in
    Darwin) route -n get default 2>/dev/null | awk '/interface:/{print $2}' ;;
    Linux)  ip route show default 2>/dev/null | awk '{print $5; exit}' ;;
    *)      : ;;
  esac
}

# BatchMode disables every interactive prompt, which is the point: if this
# succeeds, the login is genuinely non-interactive. Host keys are not
# auto-accepted - that stays the operator's decision.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20)
ssh_do() { ssh "${SSH_OPTS[@]}" -p "$TGT_SSH_PORT" "${TGT_USER}@${TGT_HOST}" "$@"; }
scp_to() { scp "${SSH_OPTS[@]}" -P "$TGT_SSH_PORT" "$1" "${TGT_USER}@${TGT_HOST}:$2"; }

require_target() {
  [[ -n "$TGT_HOST" ]] || die "no target configured - run: $0 install -H <host> --sni <domain>"
  [[ -n "$TGT_SNI"  ]] || die "no masquerade domain - run: $0 install ... --sni <domain>"
}

# True when the argument is something a client could dial: a public IP literal or
# a DNS name. An ~/.ssh/config alias ("la-server") is neither, and a private
# address is reachable only from where ssh runs, so neither counts.
dialable() {
  case "$1" in
    "") return 1 ;;
    *[!0-9.]*) : ;;                       # not a bare IPv4 - fall through
    *) case "$1" in
         10.*|127.*|0.*|192.168.*|169.254.*) return 1 ;;
         172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
         *) return 0 ;;
       esac ;;
  esac
  case "$1" in *:*) return 0 ;; esac      # IPv6 literal
  case "$1" in *.*) return 0 ;; esac      # DNS name
  return 1
}

# The address is a property of the server, never a saved setting: an address left
# over from a previous run silently produced links pointing at the wrong machine.
# It is resolved fresh every time, and the address the operator dialled wins,
# because that is the address proven to reach the machine. A server's own report
# is its *egress* address, which is not always where clients can reach it.
resolve_addr() {   # $1 = address reported by the server, may be empty
  if [[ "$ADDR_EXPLICIT" == "1" ]]; then printf '%s' "$TGT_ADDR"; return 0; fi
  if dialable "$TGT_HOST"; then printf '%s' "$TGT_HOST"; return 0; fi
  if [[ -n "$1" ]]; then
    if [[ -n "$TGT_ADDR" && "$TGT_ADDR" != "$1" ]]; then
      warn "saved address ${TGT_ADDR} differs from the server's report $1 - using $1"
    fi
    printf '%s' "$1"; return 0
  fi
  printf '%s' "$TGT_ADDR"
}

parse_opts() {
  local n=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -H|--host)     TGT_HOST="${2:?}"; shift 2 ;;
      -U|--user)     TGT_USER="${2:?}"; shift 2 ;;
      -P|--ssh-port) TGT_SSH_PORT="${2:?}"; shift 2 ;;
      --auth)        AUTH_DECL="${2:?}"; shift 2 ;;
      --name)        TGT_NAME="${2:?}"; shift 2 ;;
      --listen)      TGT_LISTEN="${2:?}"; shift 2 ;;
      --sni)         TGT_SNI="${2:?}"; shift 2 ;;
      --dir)         TGT_DIR="${2:?}"; shift 2 ;;
      --addr)        TGT_ADDR="${2:?}"; ADDR_EXPLICIT="1"; shift 2 ;;
      --label)       TGT_LABEL="${2:?}"; shift 2 ;;
      --force)       FORCE="1"; shift ;;
      --yes|-y)      YES="1"; shift ;;
      -h|--help)     usage; exit 0 ;;
      -*)            die "unknown option: $1 (run with --help)" ;;
      *)             n=$((n + 1))
                     case $n in 1) ARG1="$1" ;; 2) ARG2="$1" ;; esac
                     shift ;;
    esac
  done
}

save_target() {
  mkdir -p "$HOME_DIR"
  umask 077
  cat > "$TARGET" <<ENV
TGT_HOST=$(printf '%q' "$TGT_HOST")
TGT_USER=$(printf '%q' "$TGT_USER")
TGT_SSH_PORT=$(printf '%q' "$TGT_SSH_PORT")
TGT_NAME=$(printf '%q' "$TGT_NAME")
TGT_LISTEN=$(printf '%q' "$TGT_LISTEN")
TGT_SNI=$(printf '%q' "$TGT_SNI")
TGT_DIR=$(printf '%q' "$TGT_DIR")
TGT_ADDR=$(printf '%q' "$TGT_ADDR")
TGT_LABEL=$(printf '%q' "$TGT_LABEL")
ENV
}

validate_inputs() {
  [[ -n "$TGT_HOST" ]] || die "-H <host> is required"
  [[ -n "$TGT_SNI"  ]] || die "--sni <domain> is required (the masquerade domain)"
  [[ "$TGT_SNI" == *.* ]] || die "--sni must be a domain, got '$TGT_SNI'"
  [[ "$TGT_LISTEN" =~ ^[0-9]+$ ]] || die "--listen must be a port number"
  [[ "$TGT_SSH_PORT" =~ ^[0-9]+$ ]] || die "--ssh-port must be a port number"
  [[ "$TGT_DIR" == /* ]] || die "--dir must be an absolute path"
}

# The address clients should dial, resolved fresh. Only contacts the server when
# the SSH target is not already something dialable.
current_addr() {
  if [[ "$ADDR_EXPLICIT" == "1" ]]; then printf '%s' "$TGT_ADDR"; return 0; fi
  if dialable "$TGT_HOST"; then printf '%s' "$TGT_HOST"; return 0; fi
  local detected
  detected="$(ssh_do "curl -s4 -m 10 https://api.ipify.org 2>/dev/null || true")" || true
  resolve_addr "$detected"
}

# ------------------------------------------------------------- ssh checks ---
guide_password_only() {
  cat >&2 <<GUIDE

This host authenticates with a password, which this skill cannot use: it runs
commands non-interactively and has no way to answer a password prompt.

Use a different way in. Set up key-based login yourself first, then re-run this
command. This tool does not read, generate or upload keys, and does not touch
the server's authorized_keys.

  # on this machine, if you do not have a key yet
  ssh-keygen -t ed25519 -C "xray-reality-skill"

  # copy the public key over - you type the password once, by hand
  ssh-copy-id -p ${TGT_SSH_PORT} ${TGT_USER}@${TGT_HOST}

  # confirm the login no longer asks for anything
  ssh -p ${TGT_SSH_PORT} ${TGT_USER}@${TGT_HOST} true

  # if your key has a passphrase, load it into the agent first
  ssh-add --apple-use-keychain ~/.ssh/id_ed25519

  # or point this tool at an existing alias instead of the raw host
  #   ~/.ssh/config:  Host mynode
  #                     HostName ${TGT_HOST}
  #                     User ${TGT_USER}
  #                     IdentityFile ~/.ssh/id_ed25519
  #   then:  $0 install -H mynode --sni <domain>
GUIDE
}

guide_key_rejected() {
  cat >&2 <<GUIDE

The host accepts public keys, but the key offered was not accepted (see the
message above). This is a local key-selection problem, not a server problem.

  # see which key is offered and what the server says
  ssh -v -p ${TGT_SSH_PORT} ${TGT_USER}@${TGT_HOST} true

  # then either load the right key into the agent ...
  ssh-add --apple-use-keychain ~/.ssh/<the-right-key>

  # ... or select it with an alias and pass that to -H
  #   ~/.ssh/config:  Host mynode
  #                     HostName ${TGT_HOST}
  #                     User ${TGT_USER}
  #                     IdentityFile ~/.ssh/<the-right-key>

Adding the key to the server's authorized_keys is also your step, not this
tool's.
GUIDE
}

guide_host_key() {
  cat >&2 <<GUIDE

The host key is not in your known_hosts, and this tool does not accept host keys
automatically. Connect once yourself, check the fingerprint, then re-run:

  ssh -p ${TGT_SSH_PORT} ${TGT_USER}@${TGT_HOST} true
GUIDE
}

# Returns 0 only when a non-interactive login already works.
# Sets AUTH_MODE: key | password | key-rejected | host-key | unreachable
preflight_auth() {
  [[ -n "$TGT_HOST" ]] || die "-H <host> is required"

  if [[ "$AUTH_DECL" == "password" ]]; then
    AUTH_MODE="password"
    warn "== ssh auth =="
    warn "--auth password was declared."
    guide_password_only
    return 1
  fi
  if [[ -n "$AUTH_DECL" && "$AUTH_DECL" != "key" ]]; then
    die "--auth must be 'key' or 'password'"
  fi

  local out rc
  set +e
  out="$(ssh "${SSH_OPTS[@]}" -p "$TGT_SSH_PORT" "${TGT_USER}@${TGT_HOST}" true 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    AUTH_MODE="key"
    log "== ssh auth =="
    log "key-based, non-interactive login works"
    return 0
  fi

  log "== ssh auth =="
  case "$out" in
    *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
      AUTH_MODE="host-key"
      warn "the host key is not trusted yet"
      guide_host_key
      return 1 ;;
  esac

  local methods
  methods="$(printf '%s\n' "$out" | sed -n 's/.*Permission denied (\([^)]*\)).*/\1/p' | tail -1)"
  if [[ -n "$methods" ]]; then
    AUTH_MODE="password"
    if [[ "$methods" == *publickey* ]]; then
      AUTH_MODE="key-rejected"
      warn "server allows: ${methods}; the key offered was not accepted"
      guide_key_rejected
    else
      warn "server is password-only (allowed: ${methods})"
      guide_password_only
    fi
    return 1
  fi

  AUTH_MODE="unreachable"
  warn "could not connect:"
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  cat >&2 <<GUIDE

Check that the host name, SSH port and network path are right, and that the
host is up. Nothing was changed on either side.
GUIDE
  return 1
}

cmd_check() {
  preflight_auth || return 1
  if [[ -n "$TGT_DIR" ]]; then
    local remote
    if remote="$(ssh_do "test -d '$TGT_DIR' && echo present || echo absent" 2>/dev/null)"; then
      log "deploy dir:  $TGT_DIR ($remote)"
    fi
  fi
  log "ready: a key-based login works; install can proceed"
}

# ---------------------------------------------------------------- install ---
cmd_install() {
  validate_inputs
  preflight_auth || die "resolve the SSH login first (see the guidance above)"

  log "== target =="
  log "destination: ${TGT_USER}@${TGT_HOST}:${TGT_SSH_PORT}"
  log "deploy dir:  ${TGT_DIR}   listen=${TGT_LISTEN}   masquerade=${TGT_SNI}"
  save_target

  ssh_do "install -d -m 700 '$TGT_DIR'" || die "could not create $TGT_DIR"

  log "== installing control helper =="
  scp_to "$SKILL_DIR/assets/ctl.sh" "$TGT_DIR/ctl.sh" || die "could not copy ctl.sh"
  ssh_do "chmod 700 '$TGT_DIR/ctl.sh'"

  log "== deploying =="
  local force_flag=""
  [[ "$FORCE" == "1" ]] && force_flag="--force"
  local out
  out="$(ssh_do "'$TGT_DIR/ctl.sh' deploy --listen '$TGT_LISTEN' --sni '$TGT_SNI' --name '$TGT_NAME' $force_flag")" \
    || die "deployment failed (see the output above)"

  printf '%s\n' "$out" | redact | sed -n '/^---XRAY-INFO---$/,/^---XRAY-END---$/p' \
    | grep -vE '^---XRAY-(INFO|END)---$' || true

  local info uuid pub sid port sni addr
  info="$(printf '%s\n' "$out" | sed -n '/^---XRAY-INFO---$/,/^---XRAY-END---$/p')"
  [[ -n "$info" ]] || die "deployment finished but returned no info block"
  uuid="$(printf '%s\n' "$info" | sed -n 's/^uuid=//p' | head -1)"
  pub="$(printf '%s\n'  "$info" | sed -n 's/^publicKey=//p' | head -1)"
  sid="$(printf '%s\n'  "$info" | sed -n 's/^shortId=//p' | head -1)"
  port="$(printf '%s\n' "$info" | sed -n 's/^port=//p' | head -1)"
  sni="$(printf '%s\n'  "$info" | sed -n 's/^sni=//p' | head -1)"
  addr="$(printf '%s\n' "$info" | sed -n 's/^addr=//p' | head -1)"
  [[ -n "$uuid" && -n "$pub" ]] || die "deployment returned incomplete info"

  TGT_ADDR="$(resolve_addr "$addr")"
  [[ -n "$TGT_ADDR" ]] || TGT_ADDR="$addr"
  save_target
  write_client_files "$uuid" "$pub" "$sid" "$port" "$sni" "$TGT_ADDR"

  log ""
  log "deployed. client share link:"
  log "  $(cat "$HOME_DIR/${TGT_NAME}.link")"
  log ""
  log "next: $0 doctor    # verify end to end"
}

# The trailing fragment is the name clients show in their node list. Override it
# with --label; the agent asks the user once before deploying.
build_link() {
  local label="${TGT_LABEL:-$DEFAULT_LABEL}"
  label="${label// /%20}"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$label"
}

write_client_files() {
  local uuid="$1" pub="$2" sid="$3" port="$4" sni="$5" addr="$6"
  local link; link="$(build_link "$uuid" "$addr" "$port" "$sni" "$pub" "$sid")"
  mkdir -p "$HOME_DIR"
  umask 077
  {
    printf 'NAME=%q\n' "$TGT_NAME"
    printf 'ADDR=%q\n' "$addr"
    printf 'PORT=%q\n' "$port"
    printf 'UUID=%q\n' "$uuid"
    printf 'SNI=%q\n'  "$sni"
    printf 'PBK=%q\n'  "$pub"
    printf 'SID=%q\n'  "$sid"
    printf 'FLOW=%q\n' "xtls-rprx-vision"
    printf 'FP=%q\n'   "chrome"
    printf 'LINK=%q\n' "$link"
  } > "$HOME_DIR/${TGT_NAME}.env"
  printf '%s\n' "$link" > "$HOME_DIR/${TGT_NAME}.link"
  chmod 600 "$HOME_DIR/${TGT_NAME}.env" "$HOME_DIR/${TGT_NAME}.link"
}

# ------------------------------------------------------------------ local ---
# How the user confirms it worked on their own device.
check_hint() {
  local host="${TGT_ADDR:-}"; [[ -n "$host" ]] || host="${TGT_HOST:-}"
  printf '\nwhen you are connected on a device, open https://ipdata.co\n' >&2
  if [[ -n "$host" ]]; then
    printf 'the IP it shows should be %s\n' "$host" >&2
  else
    printf 'the IP it shows should be your server address\n' >&2
  fi
}

cmd_link() {
  [[ -f "$HOME_DIR/${TGT_NAME}.link" ]] || cmd_info
  cat "$HOME_DIR/${TGT_NAME}.link"
  check_hint
}

cmd_qr() {
  local out="$HOME_DIR/${TGT_NAME}-qr.png"
  [[ -n "$1" ]] && out="$1"
  local link_file="$HOME_DIR/${TGT_NAME}.link"
  [[ -f "$link_file" ]] || cmd_link >/dev/null
  command -v python3 >/dev/null 2>&1 || die "python3 is required for QR codes"
  local gen="$SKILL_DIR/scripts/gen_qr.py"
  [[ -f "$gen" ]] || die "missing helper: $gen"
  python3 "$gen" --link-file "$link_file" -o "$out" \
    || die 'QR generation failed; if the qrcode module is missing: pip install "qrcode[pil]"'
  check_hint
}

cmd_info() {
  require_target
  local out uuid pub sid port sni addr
  out="$(ssh_do "'$TGT_DIR/ctl.sh' info")" || die "could not read server info"
  uuid="$(printf '%s\n' "$out" | sed -n 's/^uuid=//p' | head -1)"
  pub="$(printf '%s\n'  "$out" | sed -n 's/^publicKey=//p' | head -1)"
  sid="$(printf '%s\n'  "$out" | sed -n 's/^shortIds=//p' | head -1)"
  sid="${sid%%,*}"
  port="$(printf '%s\n' "$out" | sed -n 's/^port=//p' | head -1)"
  sni="$(printf '%s\n'  "$out" | sed -n 's/^serverName=//p' | head -1)"
  [[ -n "$uuid" ]] || die "server returned no client UUID"
  if [[ -z "$pub" ]]; then
    cat >&2 <<'MISSING'
error: the server has no public.key, so the REALITY public key cannot be shown.

This skill does not read the private key out of config.json to derive it, so it
cannot reconstruct the public key. Recover it from a client that still works -
the pbk= value in that client's link IS this public key - and save it to
<deploy-dir>/public.key on the host. That is an operator action; this tool will
not do it by reading the key.
MISSING
    exit 1
  fi

  addr="$(current_addr)"
  [[ -n "$addr" ]] || die "could not determine the address clients should dial; pass --addr"
  TGT_ADDR="$addr"
  save_target
  write_client_files "$uuid" "$pub" "$sid" "$port" "$sni" "$addr"
  printf '%s\n' "$out" | redact
  log ""
  log "link: $(cat "$HOME_DIR/${TGT_NAME}.link")"
}

cmd_doctor() {
  require_target
  local port="$TGT_LISTEN" rc=0
  preflight_auth || { log "ssh is not usable; stopping here"; return 1; }

  log "== server =="
  ssh_do "'$TGT_DIR/ctl.sh' doctor" | redact || rc=1

  log "== from this machine =="
  # Use the address clients dial: the SSH target may be an alias only ssh knows.
  local host="${TGT_ADDR:-$TGT_HOST}"

  # A local VPN or proxy rewrites the path, so the checks below say nothing
  # reliable about the server. Say so instead of crying wolf.
  local dev; dev="$(default_iface)"
  case "$dev" in
    utun*|ppp*|tun*)
      log "note: this machine's default route is $dev - a local VPN/proxy is in the"
      log "      path, so the results below can be misleading. Re-check with it off."
      ;;
  esac

  # One probe does both jobs: curl must complete a TCP connection and a TLS
  # handshake. Connecting by address, so the masquerade certificate cannot match
  # - hence -k. What is being tested is that a real TLS endpoint answers, not
  # that the name verifies.
  if curl -sk -o /dev/null --connect-timeout 8 -m 15 "https://${host}:${port}/" 2>/dev/null; then
    log "${host}:${port} answered a TLS handshake (cert not verified: dialled by address)"
  else
    log "${host}:${port} did NOT answer - check the host firewall AND the cloud"; rc=1
    log "                 security group, and that this machine is not behind a"
    log "                 local VPN that mangles non-standard ports"
  fi
  return $rc
}

# Export the authoritative server state, including the REALITY private key.
# Nothing is written on the server; the copy is the operator's to place.
cmd_backup() {
  require_target
  local out
  out="$(ssh_do "'$TGT_DIR/ctl.sh' backup")" || die "backup failed"
  if [[ -n "${1:-}" ]]; then
    umask 077
    printf '%s\n' "$out" | redact > "$1"
    chmod 600 "$1"
    log "wrote $1"
    log "this file contains the REALITY private key - keep it off client machines"
  else
    printf '%s\n' "$out" | redact
  fi
}

cmd_config() {
  require_target
  log "target=${TGT_USER}@${TGT_HOST}:${TGT_SSH_PORT} name=${TGT_NAME} dir=${TGT_DIR} listen=${TGT_LISTEN} sni=${TGT_SNI} addr=${TGT_ADDR:-auto} label=${TGT_LABEL:-$DEFAULT_LABEL}"
}

cmd_shell() { require_target; exec ssh -p "$TGT_SSH_PORT" "${TGT_USER}@${TGT_HOST}"; }

cmd_uninstall() {
  require_target
  [[ "$YES" == "1" ]] || die "this stops and removes the container; re-run: $0 uninstall --yes"
  ssh_do "'$TGT_DIR/ctl.sh' down"
  log "container removed; files kept at $TGT_DIR"
}

passthrough() {
  require_target
  ssh_do "'$TGT_DIR/ctl.sh' $(printf '%q ' "$@")" | redact
}

# Print the header comment block: from line 2 to the first line that is not a
# comment. Robust to adding or removing option lines.
usage() { sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

cmd="${1:-help}"
shift || true
parse_opts "$@"

case "$cmd" in
  check)       cmd_check ;;
  install)     cmd_install ;;
  status)      passthrough status ;;
  doctor)      cmd_doctor ;;
  info)        cmd_info ;;
  backup)      cmd_backup "$ARG1" ;;
  link)        cmd_link ;;
  qr)          cmd_qr "$ARG1" ;;
  logs)        passthrough logs "${ARG1:-50}" ;;
  restart)     passthrough restart ;;
  up)          passthrough up ;;
  down)        passthrough down ;;
  update)      passthrough update ;;
  client-add)  [[ -n "$ARG1" ]] || die "usage: $0 client-add <name>"; passthrough client-add "$ARG1" ;;
  client-rm)   [[ -n "$ARG1" ]] || die "usage: $0 client-rm <name>";  passthrough client-rm "$ARG1" ;;
  client-list) passthrough client-list ;;
  rotate-keys) passthrough rotate-keys ;;
  set-port)    [[ -n "$ARG1" ]] || die "usage: $0 set-port <n>"; TGT_LISTEN="$ARG1"; save_target; passthrough set-port "$ARG1" ;;
  set-sni)     [[ -n "$ARG1" ]] || die "usage: $0 set-sni <domain>"; TGT_SNI="$ARG1"; save_target; passthrough set-sni "$ARG1" ;;
  shell)       cmd_shell ;;
  config)      cmd_config ;;
  uninstall)   cmd_uninstall ;;
  help|-h|--help) usage ;;
  *) die "unknown command: $cmd (run with --help)" ;;
esac
