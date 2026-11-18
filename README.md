# Cannoli

A preforking web server and framework for [Strada](https://github.com/strada-lang/strada).

**Repository:** https://github.com/strada-lang/cannoli

## Features

- **Preforking Architecture**: Multiple worker processes for high concurrency
- **URL Routing**: Static and regex-based URL routing with captures
- **HTTP Headers**: Full request/response header support with cookies
- **Static File Serving**: Built-in static file server with directory listing
- **SSL/HTTPS Support**: Secure connections via OpenSSL
- **FastCGI Support**: Run behind nginx, Apache, or other web servers
- **WebSockets**: Basic upgrade + frame helpers
- **Keep-Alive**: HTTP/1.1 persistent connections and pipelining
- **Hardened connection handling**: deadlines on every read and write
  (slowloris, slow readers, silent TLS clients), strict RFC 9112 framing
  against request smuggling, `Expect: 100-continue`
- **Operations**: pid file, privilege drop, trusted proxies
  (`X-Forwarded-For`/`-Proto`), request IDs, `Date` and custom default
  headers, crash-loop backoff, bounded SIGHUP/shutdown drains
- **Dynamic Libraries**: Load handlers from shared libraries (.so)
- **HTTP Method Filtering**: Route handlers for GET, POST, PUT, DELETE, etc.
- **Simple API**: Easy-to-use application framework

## Requirements

- [Strada](https://github.com/strada-lang/strada) installed (`strada` command in PATH)
- GCC
- zlib development headers (`zlib1g-dev` on Debian/Ubuntu)

## Building

```bash
git clone https://github.com/strada-lang/cannoli.git
cd cannoli
make
```

## Running

### Standalone Server

```bash
./cannoli                           # Run with defaults (port 8080, 5 workers)
./cannoli -p 3000                   # Run on port 3000
./cannoli -p 3000 -w 10            # 10 worker processes
./cannoli --config cannoli.conf    # Use configuration file
./cannoli --dev                     # Single-process development mode
```

### Static File Server

```bash
./cannoli --static /path/to/files --listing     # Serve files with directory listing
./cannoli --static ./public                      # Serve from ./public directory
./cannoli /path/to/files --listing               # Positional argument also works
```

### SSL/HTTPS Mode

```bash
./cannoli --ssl --ssl-cert cert.pem --ssl-key key.pem
./cannoli --ssl --ssl-port 8443 --ssl-cert cert.pem --ssl-key key.pem
```

### FastCGI Mode (with nginx)

```bash
./cannoli --fastcgi --socket unix:/run/cannoli/cannoli.sock   # or 127.0.0.1:9000
```

nginx configuration:
```nginx
location / {
    fastcgi_pass unix:/run/cannoli/cannoli.sock;
    fastcgi_keep_conn on;
    include fastcgi_params;
}
```

`fastcgi.socket` is `unix:/path` (or just `/path`) for a Unix-domain socket
-- created with `fastcgi.socket_mode` (default `0660`), handed to
`server.user`, removed on shutdown; a stale file from a crashed run is
replaced, a live one is refused -- or `host:port` for TCP (default
`127.0.0.1:9000`). Keep TCP on loopback or a private network: FastCGI
parameters such as `REMOTE_ADDR` and `HTTPS` are trusted as sent.

### Dynamic Library Mode

```bash
./cannoli --library ./myapp.so --dev
./cannoli -l ./lib1.so,./lib2.so    # Multiple libraries
```

## Creating Applications

### Simple Application

```strada
func handle_home(hash %req) hash {
    return Cannoli::Response::html(200, "<h1>Hello!</h1>");
}

func main() int {
    my scalar $app = Cannoli::App::new();
    Cannoli::App::get($app, "/", \&handle_home);
    return Cannoli::App::run($app);
}
```

A program that calls `Cannoli::App::run($app)` (or `run_dev`) accepts the
server's command-line options: `-p/--port`, `-h/--host`, `-w/--workers`,
`--fastcgi` and `--socket` override the defaults and any `App::configure` file.

### REST API

```strada
func list_users(hash %req) hash {
    return Cannoli::Response::json(200, "[{\"id\":1,\"name\":\"Alice\"}]");
}

func get_user(hash %req) hash {
    my scalar $caps = $req{"captures"};
    my str $id = $caps->[0];
    return Cannoli::Response::json(200, "{\"id\":\"" . $id . "\"}");
}

func create_user(hash %req) hash {
    my str $name = Cannoli::Request::get_param(%req, "name");
    return Cannoli::Response::json(201, "{\"created\":\"" . $name . "\"}");
}

func main() int {
    my scalar $app = Cannoli::App::new();
    Cannoli::App::get($app, "/api/users", \&list_users);
    Cannoli::App::get($app, "/api/users/([0-9]+)", \&get_user);
    Cannoli::App::post($app, "/api/users", \&create_user);
    return Cannoli::App::run($app);
}
```

## Request Object

The request hash contains:

| Key | Description |
|-----|-------------|
| `method` | HTTP method (GET, POST, etc.) |
| `path` | Request path |
| `uri` | Full URI including query string |
| `query_string` | Query string portion |
| `http_version` | HTTP version (HTTP/1.1) |
| `headers` | Hash reference of headers (lowercase keys) |
| `body` | Request body |
| `params` | Hash reference of query/form parameters |
| `captures` | Array reference of regex captures |
| `content_type` | Content-Type header value |
| `content_length` | Content-Length header value |
| `remote_addr` | Client IP address |
| `remote_port` | Client port |

## Request Header Functions

### Reading Headers

```strada
# Get a specific header (case-insensitive)
my str $ua = Cannoli::Request::get_header(%req, "User-Agent");
my str $host = Cannoli::Request::get_header(%req, "Host");
my str $auth = Cannoli::Request::get_header(%req, "Authorization");

# Check if header exists
if (Cannoli::Request::has_header(%req, "X-Custom-Header")) {
    # ...
}

# Get all headers as hash reference
my scalar $headers = Cannoli::Request::headers(%req);

# Get all header names as array
my array @names = Cannoli::Request::header_names(%req);
```

### Convenience Header Functions

```strada
# Common headers
my str $ua = Cannoli::Request::user_agent(%req);     # User-Agent
my str $host = Cannoli::Request::host(%req);         # Host
my str $referer = Cannoli::Request::referer(%req);   # Referer

# Content negotiation
if (Cannoli::Request::accepts_json(%req)) {
    return Cannoli::Response::json(200, $data);
}

# AJAX detection
if (Cannoli::Request::is_ajax(%req)) {
    # XMLHttpRequest
}
```

### Cookie Functions

```strada
# Get a specific cookie
my str $session = Cannoli::Request::get_cookie(%req, "session");
my str $user_id = Cannoli::Request::get_cookie(%req, "user_id");

# Get all cookies as hash
my hash %cookies = Cannoli::Request::cookies(%req);
my array @cookie_names = keys(%cookies);
```

## Response Helpers

### Basic Responses

```strada
Cannoli::Response::text(200, "Plain text")
Cannoli::Response::html(200, "<h1>HTML</h1>")
Cannoli::Response::json(200, "{\"key\":\"value\"}")
Cannoli::Response::redirect("/new-url", 0)      # 302 temporary redirect
Cannoli::Response::redirect("/new-url", 1)      # 301 permanent redirect
Cannoli::Response::not_found()
Cannoli::Response::error_page(500, "Error message")
Cannoli::Response::method_not_allowed("GET, POST")
Cannoli::Response::internal_error("Something went wrong")
```

### Setting Response Headers

```strada
func my_handler(hash %req) hash {
    my hash %res = Cannoli::Response::json(200, "{\"status\":\"ok\"}");

    # Set individual headers
    Cannoli::Response::header(%res, "X-Custom-Header", "value");
    Cannoli::Response::header(%res, "X-Request-Id", "12345");

    # Set multiple headers at once
    my hash %headers = ();
    $headers{"X-Powered-By"} = "Strada";
    $headers{"X-Version"} = "1.0";
    Cannoli::Response::headers(%res, %headers);

    return %res;
}
```

### Response Header Convenience Functions

```strada
# Caching
Cannoli::Response::cache(%res, 3600);     # Cache for 1 hour
Cannoli::Response::cache(%res, 0);        # Disable caching (no-cache)

# CORS (Cross-Origin Resource Sharing)
Cannoli::Response::cors(%res, "*");                    # Allow all origins
Cannoli::Response::cors(%res, "https://example.com"); # Specific origin

# Cookies
Cannoli::Response::set_cookie(%res, "session", "abc123", "Path=/; HttpOnly");
Cannoli::Response::set_cookie(%res, "user", "john", "Path=/; Max-Age=3600");
Cannoli::Response::set_cookie(%res, "pref", "dark", "Path=/; Secure; SameSite=Strict");
```

### Responses with Custom Headers

```strada
# One-step response with headers
my hash %custom_headers = ();
$custom_headers{"X-Custom"} = "value";
$custom_headers{"X-Request-Id"} = "12345";

Cannoli::Response::text_with_headers(200, "Hello", %custom_headers)
Cannoli::Response::html_with_headers(200, "<h1>Hi</h1>", %custom_headers)
Cannoli::Response::json_with_headers(200, "{}", %custom_headers)
```

### Inspecting Response Headers

```strada
# Check if header is set
if (Cannoli::Response::has_header(%res, "X-Custom")) { ... }

# Get header value
my str $value = Cannoli::Response::get_header(%res, "Content-Type");

# Get all headers
my scalar $headers = Cannoli::Response::get_headers(%res);

# Remove a header
Cannoli::Response::remove_header(%res, "X-Unwanted");
```

## WebSockets

```strada
func ws_echo(scalar $c) hash {
    # "" = same-origin browsers only (default), "*" = any origin,
    # or a list: "https://app.example.com, https://admin.example.com"
    my scalar $ws = $c->ws_accept("", "");
    if (!defined($ws)) {
        if ($c->get_status() == 200) { $c->bad_request("Missing WebSocket headers"); }
        return $c->build_response();
    }

    $c->ws_max_message(1048576);          # optional; 1MB is the default
    while (1) {
        my scalar $msg = $c->ws_recv();   # {type => "text"|"binary", data => ...}
        if (!defined($msg)) { last; }     # peer closed (or broke the protocol)
        $c->ws_send("echo: " . $msg->{"data"});
    }
    return $c->build_response();
}
```

`ws_recv` answers pings, reassembles fragmented messages, validates UTF-8 in
text messages, enforces the message size limit (close code 1009), rejects
unmasked or malformed client frames (1002) and completes the close
handshake. Other methods: `ws_send_binary`, `ws_ping`, `ws_close($code,
$reason)`. Use these `$c->ws_*` methods from dynamically loaded libraries;
direct `Cannoli::WebSocket::*` calls from a `.so` are not safe. Bytes a
client sends right behind its upgrade request are delivered. Not supported:
extensions such as permessage-deflate.

For hash-based handlers, call `Cannoli::WebSocket::accept(%req)`, loop on
`Cannoli::WebSocket::recv_message($ws)`, and return
`Cannoli::Response::sent(101)`.

## Complete Header Example

```strada
func handle_api(hash %req) hash {
    # Read request headers
    my str $auth = Cannoli::Request::get_header(%req, "Authorization");
    my str $content_type = Cannoli::Request::get_header(%req, "Content-Type");

    # Check authentication
    if (length($auth) == 0) {
        my hash %res = Cannoli::Response::json(401, "{\"error\":\"Unauthorized\"}");
        Cannoli::Response::header(%res, "WWW-Authenticate", "Bearer");
        return %res;
    }

    # Read cookies
    my str $session = Cannoli::Request::get_cookie(%req, "session");

    # Process request...
    my str $data = "{\"user\":\"authenticated\",\"session\":\"" . $session . "\"}";

    # Build response with custom headers
    my hash %res = Cannoli::Response::json(200, $data);

    # Set CORS headers for API
    Cannoli::Response::cors(%res, "*");

    # Set caching
    Cannoli::Response::cache(%res, 300);  # 5 minutes

    # Set custom headers
    Cannoli::Response::header(%res, "X-Request-Id", "req-12345");
    Cannoli::Response::header(%res, "X-RateLimit-Remaining", "99");

    # Set/refresh session cookie
    Cannoli::Response::set_cookie(%res, "session", $session, "Path=/; HttpOnly; Max-Age=86400");

    return %res;
}
```

## Request Functions Reference

| Function | Description |
|----------|-------------|
| `Cannoli::Request::get_header(%req, $name)` | Get header value (case-insensitive) |
| `Cannoli::Request::has_header(%req, $name)` | Check if header exists |
| `Cannoli::Request::headers(%req)` | Get all headers as hash ref |
| `Cannoli::Request::header_names(%req)` | Get array of header names |
| `Cannoli::Request::get_cookie(%req, $name)` | Get cookie value |
| `Cannoli::Request::cookies(%req)` | Get all cookies as hash |
| `Cannoli::Request::user_agent(%req)` | Get User-Agent header |
| `Cannoli::Request::host(%req)` | Get Host header |
| `Cannoli::Request::referer(%req)` | Get Referer header |
| `Cannoli::Request::accepts_json(%req)` | Check if client accepts JSON |
| `Cannoli::Request::is_ajax(%req)` | Check if XHR request |
| `Cannoli::Request::get_param(%req, $name)` | Get query/form parameter |
| `Cannoli::Request::is_get(%req)` | Check if GET request |
| `Cannoli::Request::is_post(%req)` | Check if POST request |
| `Cannoli::Request::is_put(%req)` | Check if PUT request |
| `Cannoli::Request::is_delete(%req)` | Check if DELETE request |

## Response Functions Reference

| Function | Description |
|----------|-------------|
| `Cannoli::Response::new()` | Create empty response |
| `Cannoli::Response::text($status, $content)` | Plain text response |
| `Cannoli::Response::html($status, $content)` | HTML response |
| `Cannoli::Response::json($status, $content)` | JSON response |
| `Cannoli::Response::redirect($url, $permanent)` | Redirect (0=302, 1=301) |
| `Cannoli::Response::not_found()` | 404 response |
| `Cannoli::Response::error_page($code, $msg)` | Error page |
| `Cannoli::Response::method_not_allowed($allowed)` | 405 response |
| `Cannoli::Response::internal_error($msg)` | 500 response |
| `Cannoli::Response::sent($status)` | Mark response already sent (status for logging) |
| `Cannoli::Response::header(%res, $name, $val)` | Set single header |
| `Cannoli::Response::headers(%res, %hdrs)` | Set multiple headers |
| `Cannoli::Response::get_header(%res, $name)` | Get header value |
| `Cannoli::Response::has_header(%res, $name)` | Check if header set |
| `Cannoli::Response::remove_header(%res, $name)` | Remove header |
| `Cannoli::Response::cache(%res, $seconds)` | Set cache headers (0=no-cache) |
| `Cannoli::Response::cors(%res, $origin)` | Set CORS headers |
| `Cannoli::Response::set_cookie(%res, $name, $val, $opts)` | Set cookie |
| `Cannoli::Response::text_with_headers($status, $body, %hdrs)` | Text + headers |
| `Cannoli::Response::html_with_headers($status, $body, %hdrs)` | HTML + headers |
| `Cannoli::Response::json_with_headers($status, $body, %hdrs)` | JSON + headers |
| `Cannoli::Response::status(%res, $code)` | Set status code |
| `Cannoli::Response::content_type(%res, $type)` | Set Content-Type |
| `Cannoli::Response::body(%res, $content)` | Set body |
| `Cannoli::Response::write(%res, $content)` | Append to body |

## Configuration File

```ini
[server]
host = 0.0.0.0
port = 8080
workers = 5
max_requests = 1000  # recycle a worker after N requests (0: never)
timeout = 30         # max silence while reading a request (seconds)
header_timeout = 20  # the whole header block / TLS handshake must arrive within this
body_min_rate = 1024 # after `timeout` seconds a body must average >= this many bytes/s (0: off)
write_timeout = 30   # a response write that makes no progress for this long is dropped
keep_alive = true
keep_alive_timeout = 2  # idle seconds between requests on a kept-alive connection
max_body_size = 10485760
max_header_size = 8192
shutdown_timeout = 10   # grace for stopping (SIGTERM) or retiring (SIGHUP) workers before SIGKILL
pid_file = /run/cannoli.pid
user = www-data      # drop to this user/group after binding (only when started as root)
group = www-data
trusted_proxies = 127.0.0.1, 10.0.0.0/8  # believe X-Forwarded-For/-Proto and X-Request-Id from these
request_id = true    # send X-Request-Id (generated, or a trusted proxy's)
tokens = true        # send "Server: Cannoli/1.0"
tick_interval = 30   # seconds between cannoli_tick() calls (0: no ticker)
tick_max = 1000      # ticks before the ticker is recycled
tickers = 1          # how many ticker processes
http = true          # false: no listener or request workers, tickers only

[ssl]
enabled = true
port = 443
cert = /path/to/cert.pem
key = /path/to/key.pem

[fastcgi]
enabled = false
socket = 127.0.0.1:9000

[headers]            # added to every response that does not set them itself
X-Content-Type-Options = nosniff
Referrer-Policy = strict-origin-when-cross-origin

[static]
root = ./public
listing = true

[app]
library = lib1.so, lib2.so

[log]
level = info
```

Set `server.keep_alive = false` or pass `--no-keep-alive` to always close each response.
`static.cache_max_age = N` adds `Cache-Control: public, max-age=N` to static
files; files over 256KB are streamed from disk rather than loaded into memory.
Compressible files (text, JSON, JS, CSS, SVG, ...) are served from a
precompressed `file.br` / `file.gz` next to them when the client accepts it
and it is at least as new (`static.precompressed`, default on), otherwise
gzipped on the fly between 256B and 1MB (`static.gzip`, default on), with
`Vary: Accept-Encoding` and a per-encoding ETag. Range requests get the
uncompressed bytes.

Sessions are stored under `/tmp/cannoli_sessions` (or the directory given to
`Cannoli::Session::configure`) only if it is a private directory owned by the
server user; otherwise a per-user `...-<uid>` directory is used. Call
`$c->session_regenerate()` after a login to issue a new session ID.
`$c->set_cookie(name, value, path, max_age)`: `max_age` > 0 persists the
cookie, 0 or -1 makes it a browser-session cookie; `$c->expire_cookie(name)`
deletes one.
Command-line options override the config file regardless of their order.
`cannoli -t -c FILE` validates a configuration without starting.

## Running in Production

- **Build optimized**: `make` (the default). `make STRADA_FLAGS="-O0 --no-lto"`
  gives fast, unoptimized development builds.
- **Behind a reverse proxy** (recommended for TLS termination, HTTP/2 and
  static assets): bind to loopback and list the proxy in
  `server.trusted_proxies`; `$c->remote_addr()` then reports the client from
  `X-Forwarded-For`, `$c->scheme()` / `$c->is_secure()` honor
  `X-Forwarded-Proto` (session cookies get `Secure` automatically), and the
  proxy's `X-Request-Id` is reused. The admin endpoint is always authorized
  by the real socket address, never by forwarded headers.
- **Directly on ports 80/443**: start as root with `server.user`/`server.group`;
  sockets are bound first, then the master and all workers switch user
  (supplementary groups are reset, configured log files are chowned to the
  new user). Libraries' `cannoli_init` runs before the switch. The pid file
  stays root-owned, so the unprivileged master may not be able to remove it.
- **FastCGI mode** honors `pid_file`, `user`/`group` and `max_body_size`; the
  connection timeouts above apply to HTTP/HTTPS mode (FastCGI's peer is the
  trusted front-end server).
- **Timeouts**: every request read is bounded (`header_timeout`, `timeout`,
  `body_min_rate`) and every response write (`write_timeout`), so slow or
  silent clients cannot hold workers; a client that times out mid-request
  gets `408`. Size limits answer `413`/`431`; malformed or ambiguous framing
  (whitespace before a colon, bare CR/LF, obsolete line folding, TE with
  Content-Length, duplicate Host, invalid chunk sizes/extensions) gets `400`.
- **Process supervision**: write a `pid_file` for init scripts, or run under
  systemd (`Type=simple`, `KillSignal=SIGTERM`, `ExecReload=/bin/kill -HUP $MAINPID`).
  A handler that throws produces a `500` (details go to the error log, not the
  client) and the worker keeps serving; workers that crash right after
  starting are respawned with exponential backoff instead of a fork storm.
- **Logs** are reopened on every write, so `logrotate` needs no signal.
  Access-log fields that come from the client are escaped.
- **systemd**: `contrib/cannoli.service` (Type=notify -- Cannoli reports
  READY / RELOADING / STOPPING and pings `WatchdogSec`), `contrib/cannoli.conf`
  (an annotated production configuration) and `contrib/nginx-proxy.conf`.
- **Reload** (`systemctl reload cannoli` / SIGHUP): the config file is
  re-read and validated -- an invalid one is rejected and the running
  configuration stays -- then a fresh worker generation starts with the new
  settings and the old one drains. TLS certificates and settings are
  reloaded too (point a certbot deploy hook at `systemctl reload`).
  Listener, user, pid-file, worker-mode and library changes are reported as
  needing a restart. Command-line options keep overriding the file.
- **Health and metrics**: `server.health_path = /healthz` answers
  `{"status":"ok","workers":N,"busy":M,"uptime_sec":S}` (exempt from rate
  limits, cheap enough for load-balancer probes). With `[admin] enabled`,
  `/__admin/metrics` serves Prometheus text: requests by status class, a
  latency histogram, bytes, open connections, busy/idle workers, timeouts,
  handler errors and limit rejections -- summed across all workers through
  a shared-memory scoreboard.
- **Per-client limits**: `server.max_connections_per_ip` caps simultaneous
  connections from one socket address (trusted proxies exempt; excess
  connections get 429 and are closed); `server.rate_limit` /
  `server.rate_limit_window` cap requests per client address (the forwarded
  address behind a trusted proxy) with a 429 and `Retry-After`. Both are
  shared across workers.
- **TLS** (direct HTTPS): the full chain in `ssl.cert` (e.g. Let's Encrypt
  `fullchain.pem`) is served; `ssl.min_version` (1.2 default, or 1.3),
  `ssl.ciphers` (TLS 1.2; default: ECDHE with AES-GCM / ChaCha20 only),
  `ssl.ciphersuites` (TLS 1.3), server cipher preference, no renegotiation,
  ALPN `http/1.1`. For HTTP/2 or HTTP/3, put nginx/Caddy in front.
- **Robustness testing**: `t/test_fuzz.strada` (parser fuzzing; seed and
  size via `CANNOLI_FUZZ_SEED` / `CANNOLI_FUZZ_ITERS`), `t/test_fuzz_http.sh`
  (malformed requests against live servers; `tools/fuzz_http.py`), and
  `tools/soak.sh [seconds] [concurrency]` (sustained load with worker memory
  sampling). `sudo t/test_privdrop.sh` checks the privilege drop as root.

## Dynamic Library Interface

Create handlers in C/Strada that compile to shared libraries:

```c
// myapp.c
char* cannoli_dispatch(const char* method, const char* path,
                       const char* path_info, const char* body) {
    if (strcmp(path, "/api/hello") == 0) {
        return strdup("{\"message\":\"Hello from C!\"}");
    }
    return strdup("");  // 404
}
```

Build and run:
```bash
gcc -shared -fPIC -o myapp.so myapp.c
./cannoli --library ./myapp.so --dev
```

Return value conventions:
- Response body (auto-detects JSON/HTML)
- Empty string for 404
- `STATUS:code:content` for custom status
- `REDIRECT:url` for redirects

## Examples

See the `examples/` directory:

- `headers_demo.strada` - HTTP headers demonstration
- `static_server.strada` - Static file server
- `api_app.strada` - REST API example

## Architecture

```
                    +------------------+
                    |  Master Process  |
                    |  (manages pool)  |
                    +--------+---------+
                             |
        +--------------------+--------------------+
        |                    |                    |
   +----v----+          +----v----+          +----v----+
   | Worker 1|          | Worker 2|          | Worker N|
   |         |          |         |          |         |
   +---------+          +---------+          +---------+
```

- Master process spawns and monitors workers
- Each worker handles requests independently
- Workers recycle after `max_requests`
- Background jobs: a library that exports `cannoli_tick()` gets one extra
  process, the ticker, that calls it every `tick_interval` seconds. It is
  respawned if it dies, recycled after `tick_max` ticks, and stopped (with
  `cannoli_worker_exit()`) on shutdown. A tick that throws is logged.
  `tickers = N` runs N of them; `http = false` makes a background-job
  server with only tickers (for a job queue's workers on another machine).
- Graceful shutdown via SIGTERM/SIGINT
- Zero-downtime worker rotation via SIGHUP (starts a fresh worker generation,
  then drains the old generation). Listener and configuration changes require
  a new master process.

## License

GNU General Public License v2. See [LICENSE](LICENSE) for details.

Part of the [Strada](https://github.com/strada-lang/strada) project.
