#!/bin/bash
# Start Cannoli with the Terminale web terminal.
#
#   ./start.sh -u me                       # asks for a password, http://127.0.0.1:7681
#   ./start.sh -c terminale.conf -p 8022   # login from a config file
#   ./start.sh -u me -H 0.0.0.0 --ssl      # HTTPS with a self-signed certificate
#   ./start.sh -u me -H 0.0.0.0 --tls cert.pem key.pem
#
# --ssl serves HTTPS with a self-signed certificate that is generated on
# first use (your browser will ask you to accept it once); --tls uses your
# own certificate. Without either it is plain HTTP.
#
# Run ./start.sh --help for all options.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=7681
HOST=127.0.0.1
USER_NAME=""
PASSWORD=""
PASSWORD_SET=0
CONFIG=""
WORKERS=2
CERT=""
KEY=""
SSL=0
PIDFILE=""
MAX_UPLOAD=100
CANNOLI="${CANNOLI:-}"
EXTRA=()

usage() {
cat <<USAGE
Usage: $0 [options] [-- extra cannoli options]

  -p, --port PORT        port to listen on (default 7681)
  -H, --host HOST        address to bind (default 127.0.0.1; 0.0.0.0 or :: for all)
  -u, --user NAME        login username
  -P, --password PASS    login password (visible in the process list for a
                         moment; omit it to be prompted, or set TERMINALE_PASSWORD)
  -c, --config FILE      configuration file with user / password (see
                         terminale.conf.example); -u / -P override it
      --ssl              serve HTTPS with a self-signed certificate (generated
                         on first use, kept in ~/.terminale/tls)
      --tls CERT KEY     serve HTTPS with your own certificate chain and key
  -w, --workers N        worker processes (default 2)
      --max-upload MB    largest file that can be uploaded (default 100)
      --pid-file FILE    write Cannoli's PID to FILE
      --cannoli PATH     cannoli binary (default: ../cannoli, then \$PATH)
      --rebuild          rebuild terminale.so first
  -h, --help             this help

The terminals run as $(id -un). Sessions keep running when you close the
browser or stop this server; sign in again to get them back.
USAGE
}

REBUILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--port) PORT="$2"; shift 2 ;;
        -H|--host) HOST="$2"; shift 2 ;;
        -u|--user) USER_NAME="$2"; shift 2 ;;
        -P|--password) PASSWORD="$2"; PASSWORD_SET=1; shift 2 ;;
        -c|--config) CONFIG="$2"; shift 2 ;;
        --tls) CERT="$2"; KEY="$3"; shift 3 ;;
        --ssl) SSL=1; shift ;;
        -w|--workers) WORKERS="$2"; shift 2 ;;
        --pid-file) PIDFILE="$2"; shift 2 ;;
        --max-upload) MAX_UPLOAD="$2"; shift 2 ;;
        --cannoli) CANNOLI="$2"; shift 2 ;;
        --rebuild) REBUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; EXTRA=("$@"); break ;;
        *) echo "start.sh: unknown option $1 (try --help)" >&2; exit 2 ;;
    esac
done

case "$PORT" in ''|*[!0-9]*) echo "start.sh: invalid port '$PORT'" >&2; exit 2 ;; esac
case "$MAX_UPLOAD" in ''|*[!0-9]*) echo "start.sh: invalid --max-upload '$MAX_UPLOAD' (megabytes)" >&2; exit 2 ;; esac

if [ -z "$CANNOLI" ]; then
    if [ -x "$HERE/../cannoli" ]; then CANNOLI="$HERE/../cannoli"
    elif command -v cannoli >/dev/null; then CANNOLI="$(command -v cannoli)"
    else echo "start.sh: cannoli binary not found (build it with 'make' in $HERE/.. or pass --cannoli PATH)" >&2; exit 1
    fi
fi

if [ "$REBUILD" = 1 ] || [ ! -f "$HERE/terminale.so" ] || [ "$HERE/terminale.strada" -nt "$HERE/terminale.so" ]; then
    "$HERE/build.sh"
fi

if [ -n "$CONFIG" ]; then
    [ -f "$CONFIG" ] || { echo "start.sh: config file not found: $CONFIG" >&2; exit 1; }
    CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
fi

# Login: -u/-P, else the environment, else the config file; prompt as a last resort.
[ -n "$USER_NAME" ] && export TERMINALE_USER="$USER_NAME"
[ "$PASSWORD_SET" = 1 ] && export TERMINALE_PASSWORD="$PASSWORD"
if [ -z "$CONFIG" ]; then
    if [ -z "${TERMINALE_USER:-}" ]; then
        [ -t 0 ] || { echo "start.sh: no login configured (use -u/-P, -c FILE or TERMINALE_USER/TERMINALE_PASSWORD)" >&2; exit 1; }
        read -r -p "Login username [$(id -un)]: " TERMINALE_USER
        export TERMINALE_USER="${TERMINALE_USER:-$(id -un)}"
    fi
    if [ -z "${TERMINALE_PASSWORD:-}" ] && [ -z "${TERMINALE_PASSWORD_HASH:-}" ]; then
        [ -t 0 ] || { echo "start.sh: no password configured (use -P, -c FILE or TERMINALE_PASSWORD)" >&2; exit 1; }
        read -r -s -p "Login password for $TERMINALE_USER: " TERMINALE_PASSWORD; echo
        read -r -s -p "Again: " AGAIN; echo
        [ "$TERMINALE_PASSWORD" = "$AGAIN" ] || { echo "start.sh: passwords do not match" >&2; exit 1; }
        [ -n "$TERMINALE_PASSWORD" ] || { echo "start.sh: empty password" >&2; exit 1; }
        export TERMINALE_PASSWORD
    fi
fi

LIB="$HERE/terminale.so:static=$HERE/static"
[ -n "$CONFIG" ] && LIB="$LIB;config=$CONFIG"

# Server settings that have no command-line flag go in a small generated
# config file (the options below override it).
SRVCONF="${TMPDIR:-/tmp}/terminale-$(id -u)-$PORT.conf"
( umask 077; printf '# generated by terminale/start.sh\n[server]\nmax_body_size = %s\nmax_header_size = 16384\n' "$(( (MAX_UPLOAD + 1) * 1048576 ))" > "$SRVCONF" )

# Loop workers: each open terminal is a parked task, not a pinned process.
# A worker is recycled after 5000 connections; its open terminals are handed
# to another worker (the browser reconnects in a moment, sessions carry on).
ARGS=(-c "$SRVCONF" -h "$HOST" -w "$WORKERS" --loop-workers --max-requests 5000 -l "$LIB")
# Plain HTTP unless --ssl or --tls. With --ssl a self-signed certificate is
# kept in ~/.terminale/tls and (re)made when missing, about to expire, or
# when the address being served is not one of its names.
SCHEME=http
SELF_SIGNED=0
if [ "$SSL" = 0 ] && [ -z "$CERT" ]; then
    ARGS+=(-p "$PORT")
else
    SCHEME=https
    if [ -n "$CERT" ]; then
        [ -f "$CERT" ] && [ -f "$KEY" ] || { echo "start.sh: --tls needs a certificate and a key file" >&2; exit 1; }
    else
        command -v openssl >/dev/null || { echo "start.sh: --ssl needs openssl to make the self-signed certificate (install it, or pass --tls CERT KEY)" >&2; exit 1; }
        TLSDIR="$HOME/.terminale/tls"
        ( umask 077; mkdir -p "$HOME/.terminale" "$TLSDIR" )
        CERT="$TLSDIR/cert.pem"; KEY="$TLSDIR/key.pem"
        NAMES="DNS:localhost,IP:127.0.0.1,IP:::1"
        HN="$(hostname 2>/dev/null || true)"; FQ="$(hostname -f 2>/dev/null || true)"
        [ -n "$HN" ] && NAMES="$NAMES,DNS:$HN"
        [ -n "$FQ" ] && [ "$FQ" != "$HN" ] && NAMES="$NAMES,DNS:$FQ"
        case "$HOST" in
            0.0.0.0|::|'*'|'')      # every address: name the ones this machine has
                for ip in $(hostname -I 2>/dev/null); do NAMES="$NAMES,IP:$ip"; done ;;
            127.0.0.1|::1|localhost) ;;
            *[!0-9.]*:*|*:*) NAMES="$NAMES,IP:$HOST" ;;
            *[!0-9.]*) NAMES="$NAMES,DNS:$HOST" ;;
            *) NAMES="$NAMES,IP:$HOST" ;;
        esac
        if [ ! -s "$CERT" ] || [ ! -s "$KEY" ] || [ "$(cat "$TLSDIR/names" 2>/dev/null)" != "$NAMES" ] \
           || ! openssl x509 -in "$CERT" -noout -checkend 2592000 >/dev/null 2>&1; then
            echo "Generating a self-signed certificate in $TLSDIR ..."
            ( umask 077; openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 825 \
                -keyout "$KEY.new" -out "$CERT.new" -subj "/CN=Terminale on ${HN:-localhost}" \
                -addext "subjectAltName=$NAMES" -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 ) \
                || { rm -f "$KEY.new" "$CERT.new"; echo "start.sh: openssl could not create the self-signed certificate (pass --tls CERT KEY instead)" >&2; exit 1; }
            mv "$KEY.new" "$KEY"; mv "$CERT.new" "$CERT"; printf '%s' "$NAMES" > "$TLSDIR/names"
        fi
        SELF_SIGNED=1
    fi
    ARGS+=(--ssl-only --ssl-port "$PORT" --ssl-cert "$CERT" --ssl-key "$KEY")
fi
[ -n "$PIDFILE" ] && ARGS+=(--pid-file "$PIDFILE")

case "$HOST" in
    127.*|localhost|::1) ;;
    *) [ "$SCHEME" = http ] && echo "WARNING: listening on $HOST without TLS -- the password and everything typed
         travel unencrypted. Add --ssl (self-signed) or --tls CERT KEY, or keep -H 127.0.0.1
         behind an HTTPS proxy or SSH tunnel." >&2 ;;
esac
SHOW_HOST="$HOST"; case "$HOST" in 0.0.0.0|::|'*') SHOW_HOST="$(hostname)";; *:*) SHOW_HOST="[$HOST]";; esac
echo "Terminale: $SCHEME://$SHOW_HOST:$PORT/   (shells run as $(id -un); Ctrl+C stops the server, not the terminals)"
if [ "$SELF_SIGNED" = 1 ]; then
    echo "Self-signed certificate: your browser will warn once -- check this fingerprint before accepting:"
    echo "  $(openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=/SHA-256 /')"
fi
exec "$CANNOLI" "${ARGS[@]}" "${EXTRA[@]}"
