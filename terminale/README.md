# Terminale

A web terminal for [Cannoli](../README.md): a loadable module
(`terminale.so`) that gives you your shell in a browser, with tabs, and
sessions that keep running when you close the browser.

- **Tabs**: each tab is its own shell. Rename by double-clicking, reorder by
  dragging, right-click for the tab menu. **Split view** shows two terminals
  side by side.
- **Sessions persist**: closing a tab's page, the browser, or losing the
  connection only detaches. Open the page again and every running terminal
  comes back with its scrollback; full-screen programs (vim, htop, ...) are
  repainted and their mouse / paste modes restored. Sessions even survive a
  restart of Cannoli. A terminal ends when its shell exits or you close its
  tab with the x.
- **Detach** a tab (right-click, or Alt+Shift+D) to close it in this browser
  while it keeps running; the **sessions menu** lists every running session
  -- open here, open in another browser, or detached -- to re-attach or end.
- **Files**: browse from the terminal's current directory, click to
  download, upload with the button or by dropping files on the page.
- **Search** the scrollback (Ctrl+Shift+F; case and regex options).
- **Phones and tablets**: an on-screen row of Esc, Tab, sticky Ctrl/Alt,
  arrows, Home/End, PgUp/PgDn and Paste.
- **Clipboard**: programs can copy to your clipboard (tmux, vim, anything
  using OSC 52); they can never read it.
- **Full screen** (Chromium): browser shortcuts such as Ctrl+W and Ctrl+T go
  to the terminal. The page can also be installed as an app.
- **Settings** (the gear button, or Ctrl+Shift+,): 10 colour themes (dark
  and light), font and size, line height, cursor, scrollback length, copy on
  select, right-click paste, confirm-before-close, bell, GPU rendering. They
  apply instantly to every open terminal and are saved in
  `~/.terminale/settings.json`, so they follow you to any browser.
- **Login**: one username and password, from a config file, the command
  line, or the environment -- optionally with **two-factor** codes from an
  authenticator app. Settings show who is signed in and recent attempts, and
  can sign the other browsers out.
- **Local files only**: no database. Logins and session sockets live in
  `~/.terminale` (mode 0700).

The shells run as **the user that starts Cannoli**. Anyone who can sign in
has that user's shell, so pick a real password and use HTTPS (or an SSH
tunnel) for anything beyond localhost.

## Quick start

```bash
cd terminale
./start.sh -u me              # asks for a password, then http://127.0.0.1:7681/
./start.sh -u me --ssl        # the same over HTTPS, with a self-signed certificate
```

`--ssl` serves HTTPS with a **self-signed certificate**, generated on first
use and kept in `~/.terminale/tls/` (it needs `openssl`). Your browser warns
about it once; compare the SHA-256 fingerprint it shows with the one
`start.sh` prints, then accept. Use `--tls CERT KEY` for a real certificate.
Without either option it is plain HTTP -- fine on 127.0.0.1 or behind an
HTTPS proxy or SSH tunnel, not on an open network.

`start.sh` builds `terminale.so` on first use (needs the `strada` compiler
and a built `../cannoli`).

```
./start.sh [options] [-- extra cannoli options]
  -p, --port PORT        port (default 7681)
  -H, --host HOST        bind address (default 127.0.0.1)
  -u, --user NAME        login username
  -P, --password PASS    login password (omit to be prompted)
  -c, --config FILE      config file with the login (see below)
      --ssl              HTTPS with a generated self-signed certificate
      --tls CERT KEY     HTTPS with your own certificate
  -w, --workers N        worker processes (default 2)
      --max-upload MB    largest uploadable file (default 100)
      --pid-file FILE    write Cannoli's PID
      --cannoli PATH     cannoli binary to use
      --rebuild          rebuild terminale.so first
```

Examples:

```bash
./start.sh -c terminale.conf -p 8022
./start.sh -u me -H 0.0.0.0 -p 8443 --tls fullchain.pem privkey.pem
TERMINALE_USER=me TERMINALE_PASSWORD=secret ./start.sh        # no prompt
./start.sh -u me -H 0.0.0.0 --ssl                              # reachable from the network, encrypted
ssh -L 7681:127.0.0.1:7681 host    # then open http://127.0.0.1:7681/ locally
```

## Login configuration

Three ways, later ones override earlier ones:

1. **Config file** (`./start.sh -c terminale.conf`, or `config=/path` on the
   `-l` line). Copy `terminale.conf.example`, `chmod 600` it:

   ```ini
   user = me
   password_hash = $6$...        # from: openssl passwd -6
   # or:  password = plain-text-password
   ```

2. **Parameters when starting Cannoli**: options after the module path,
   separated by `;`:

   ```bash
   cannoli --loop-workers --max-requests 0 -p 7681 \
     -l "/path/terminale/terminale.so:static=/path/terminale/static;user=me;password=secret"
   ```

   (A password given this way is visible in the process list, and cannot
   contain `;`. Prefer the config file or the environment.)

3. **Environment**: `TERMINALE_USER`, `TERMINALE_PASSWORD` or
   `TERMINALE_PASSWORD_HASH`. The module removes the password from the
   environment once it has read it.

Without a username and password the module refuses to load.

### Two-factor sign-in

```bash
./totp-setup.sh terminale.conf     # prints a secret (and a QR code if qrencode is installed)
```

Add the secret to an authenticator app and restart. Sign-in then needs the
password and the current 6-digit code; a code works once. Without a config
file, pass `TERMINALE_TOTP_SECRET` in the environment.

All options (config file or `-l` line):

| Option | Default | |
|---|---|---|
| `user` | - | login username (required) |
| `password` / `password_hash` | - | plain password, or a crypt(3) hash (required) |
| `totp_secret` | - | base32 secret: sign-in also needs an authenticator code |
| `login_ttl` | 604800 | seconds a sign-in lasts |
| `shell` | your login shell | program to run in each terminal |
| `max_sessions` | 32 | running terminals allowed at once |
| `idle_timeout` | 0 | end terminals nobody is attached to for N seconds (0 = never) |
| `max_download` | 268435456 | largest file (bytes) the Files panel will download |
| `dir` | `~/.terminale` | where logins and session sockets are kept |
| `static` | - | path to the `static/` directory (start.sh sets it) |
| `config` | - | config file to read (`-l` line only) |

Five failed logins from one address lock that address out for five minutes.
Sign-ins and attempts are recorded in `~/.terminale/auth/login.log`; expired
sign-ins are cleaned up automatically.

## Keys

| | |
|---|---|
| Alt+Shift+T | new terminal |
| Alt+Shift+W | close terminal (ends its shell) |
| Alt+Shift+D | detach terminal (keeps running) |
| Alt+Shift+S | split view on / off |
| Ctrl+Shift+F | search scrollback |
| Alt+Shift+Left / Right | previous / next tab |
| Alt+1 ... Alt+9 | go to tab |
| Ctrl+Shift+C / Ctrl+Shift+V | copy selection / paste |
| Ctrl+Shift+, | open / close settings |
| Ctrl + / Ctrl - / Ctrl 0 | larger / smaller / default font size |
| double-click a tab | rename (empty name: follow the program's title again) |
| middle-click a tab | close |

Selecting text copies with the usual browser shortcuts too; links are
clickable.

## Running it differently

- **Loop workers are recommended** (`--loop-workers`, what `start.sh` uses):
  every open terminal is a parked task. With classic workers it also works,
  but each open tab occupies one worker for as long as it is open -- give it
  more workers than tabs. Workers recycle normally (`--max-requests`): a
  recycling worker hands its terminals to a fresh one, the browser
  reconnects in a moment and the sessions carry on.
- **As a service**: `terminale.service` is a systemd user unit.
- **Two browsers on one session** share its size: the one you are using
  sets it, the other follows and takes it back when you return to it.
- **Uploads** are limited by `--max-upload` (Cannoli's `server.max_body_size`);
  downloads by `max_download`. Both are held in memory while in transit.
- **Under a path**: in a Cannoli config, `library./term = /path/terminale.so:config=...`
  serves it at `/term/`.
- **Behind nginx**: proxy the location with the WebSocket headers (see
  `../contrib/nginx-proxy.conf`), and set `server.trusted_proxies` so the
  login lockout and the `Secure` cookie flag see the real client and scheme
  (without it every client shares the proxy's address and one attacker can
  lock everyone out; Terminale logs a warning when it detects this).
- Rebuild after changing `terminale.strada`: `./build.sh` (`--fast` for a
  quick unoptimized build).

## How it works

Each terminal is a small detached process (`terminale: session <id>` in
`ps`) that owns the PTY and the shell, keeps the last 2MB of output, and
listens on a Unix socket in `~/.terminale/sessions/`. The browser speaks
WebSocket to any Cannoli worker, which attaches to that socket and relays
bytes both ways, with flow control so a flood of output cannot swamp the
browser. Because the session lives outside the web server, workers can be
recycled or the whole server restarted without touching your shells.

A sign-in is a random token in an `HttpOnly`, `SameSite=Strict` cookie
(`Secure` over HTTPS), stored as a file in `~/.terminale/auth/`. State-changing
requests and WebSocket upgrades from other origins are refused.

To end every session by hand: `pkill -f '^terminale: session'`.

## Tests

`t/test.sh` runs the end-to-end suite (login, two-factor, sessions,
re-attach with scrollback and terminal modes, files, settings, sign-in
management, 20MB output flood, large paste, lockout, worker recycling)
against loop and classic workers, HTTP and HTTPS, using a throwaway state
directory. It also runs as part of Cannoli's `t/run_tests.sh`.

`t/browser.js` drives the page in headless Chrome (files panel, search,
split view, detach and re-attach, tab menu and reordering, touch keys, 20
tabs): `npm i puppeteer-core`, start a server, then
`node t/browser.js http://127.0.0.1:7681/ USER PASSWORD`.

## Third-party

To add a colour theme, append an entry to `static/themes.js` (terminal
palette plus the interface colours) and reload the page.

`static/xterm.js`, `xterm.css` and the `addon-*.js` files are
[xterm.js](https://xtermjs.org/) 6.0.0 and its fit, web-links and WebGL
and search addons, MIT licensed (`static/XTERM-LICENSE`).
