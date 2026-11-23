# Cannoli Internal Documentation

This document provides comprehensive internal documentation for the Cannoli web server framework, designed to help Claude and other AI assistants understand the codebase architecture, conventions, and implementation details.

## Overview

**Cannoli** is a preforking HTTP web server and application framework written in [Strada](https://github.com/strada-lang/strada), a statically-typed language with Perl-like syntax that compiles to C.

**Key characteristics:**
- Preforking architecture for high concurrency
- Full HTTP/1.1 support with headers, cookies, and all HTTP methods
- Regex-based URL routing with capture groups
- SSL/HTTPS support via OpenSSL
- FastCGI support for running behind nginx/Apache
- File-based session management
- Mustache-like template engine
- Comprehensive logging system

---

## Project Structure

```
/home/mflickin/p/cannoli/
├── src/                          # Core source files (~14,100 lines)
│   ├── main.strada              # Entry point, CLI parsing (~590 lines)
│   ├── server.strada            # Preforking HTTP server, connection layer, scoreboard (~3,500 lines)
│   ├── router.strada            # URL routing engine, middleware (~910 lines)
│   ├── request.strada           # HTTP request parsing, path normalisation (~1,180 lines)
│   ├── response.strada          # HTTP response building (~700 lines)
│   ├── cannoli_obj.strada       # OOP request/response wrapper (~1,770 lines)
│   ├── websocket.strada         # WebSocket protocol (~750 lines)
│   ├── tls.strada               # TLS transport over Strada's ssl module (~190 lines)
│   ├── app.strada               # Application framework API (~260 lines)
│   ├── config.strada            # Configuration file parser + validation (~480 lines)
│   ├── log.strada               # Logging, rotation (~570 lines)
│   ├── session.strada           # Session management (~480 lines)
│   ├── template.strada          # Template rendering engine (~940 lines)
│   ├── static.strada            # Static file serving (~590 lines)
│   ├── fastcgi.strada           # FastCGI protocol (~660 lines)
│   ├── validation.strada        # Input validation helpers (~500 lines)
│   └── mime.strada              # MIME type mapping (~46 lines)
├── lib/                          # Extensions
│   ├── compress.strada          # Compression utilities
│   ├── perl/                    # Perl handlers (embedded interpreter; `make`, `make test`)
│   └── perla/                   # Experimental Perla prototype (not maintained)
├── examples/                     # Example applications
├── t/                            # Test suite
├── build/                        # Build artifacts
├── Makefile                      # Build configuration
└── cannoli                       # Compiled binary
```

---

## Language: Strada

Cannoli is written in **Strada**, which has the following key characteristics:

### Types
```strada
int      # 64-bit signed integer
num      # 64-bit floating-point
str      # UTF-8 string
scalar   # Dynamic type (can hold any value including references)
array    # Ordered list
hash     # Key-value map (string keys)
void     # No return value
```

### Variables (sigils like Perl)
```strada
my int $count = 0;           # Scalar
my array @items = ();        # Array
my hash %data = ();          # Hash
my scalar $ref = \%data;     # Reference
```

### Functions
```strada
func function_name(type $param1, type $param2) return_type {
    # body
}
```

### OOP Convention
Strada uses a Perl-style OOP pattern with blessed hash references:
```strada
# Constructor: ClassName_new()
func ClassName_new(params) scalar {
    my hash %self = ();
    $self{"field"} = value;
    return bless(\%self, "ClassName");
}

# Method: ClassName_method($self, ...)
func ClassName_method(scalar $self, params) return_type {
    return $self->{"field"};
}

# Method call: $obj->method()
my scalar $obj = ClassName_new();
$obj->method();
```

### Key Language Features
- `ref($var)` returns type: "hash", "array", "ref", or "" for scalars
- `exists(%hash, "key")` checks key existence
- `defined($var)` checks if variable is defined
- `scalar(@array)` returns array length
- `keys(%hash)` returns array of keys
- `bless(\%hash, "ClassName")` creates blessed object
- `sys::` namespace for system calls (open, close, fork, etc.)
- `split()` takes a **regex** (Perl semantics): `split(".", $ip)` returns nothing; use `split("\\.", $ip)`
- `index()` counts characters on UTF-8 strings but bytes on byte data (socket input), so request framing on received data is byte-accurate
- `math::` namespace for math functions (sqrt, sin, rand, etc.)

---

## Core Architecture

### Module Dependency Graph

```
main.strada
    ↓
app.strada
    ↓
┌───────────────────────────────────────────┐
│           server.strada                    │
│  (preforking, socket handling, SSL)        │
└───────────────────────────────────────────┘
    ↓                    ↓
router.strada       config.strada
    ↓
┌───────────────┐  ┌───────────────┐
│request.strada │  │response.strada│
└───────────────┘  └───────────────┘
         ↓
cannoli_obj.strada (OOP wrapper)
         ↓
┌─────────────────────────────────────┐
│ Supporting modules:                  │
│ - log.strada (logging)               │
│ - session.strada (sessions)          │
│ - template.strada (templating)       │
│ - static.strada (file serving)       │
│ - fastcgi.strada (FastCGI protocol)  │
│ - validation.strada (input checks)   │
└─────────────────────────────────────┘
```

### Process Model

```
                    ┌──────────────────┐
                    │  Master Process  │
                    │  (manages pool)  │
                    └────────┬─────────┘
                             │ fork()
        ┌────────────────────┼────────────────────┐
        │                    │                    │
   ┌────v────┐          ┌────v────┐          ┌────v────┐
   │ Worker 1│          │ Worker 2│          │ Worker N│
   │(handles │          │(handles │          │(handles │
   │requests)│          │requests)│          │requests)│
   └─────────┘          └─────────┘          └─────────┘
```

- **Master process**: Spawns workers, monitors health, handles signals (SIGTERM, SIGHUP)
- **Worker processes**: Each handles requests independently, recycles after `max_requests`
- **Request flow**: Socket accept → Parse request → Route → Handler → Response → Log

---

## Core Modules Reference

### 1. main.strada (Entry Point)

**Purpose:** CLI argument parsing and application bootstrap.

**Key functions:**
- `main()` - Entry point, parses args, starts server
- `show_help()` - Displays usage information
- `show_version()` - Displays version

**CLI options:**
| Flag | Description |
|------|-------------|
| `-p, --port` | Port number (default: 8080) |
| `-w, --workers` | Worker count (default: 5) |
| `-h, --host` | Bind address (default: 0.0.0.0) |
| `--config` | Path to config file |
| `--dev` | Single-process development mode |
| `--debug` | Enable debug logging |
| `--static` | Static file serving directory |
| `--listing` | Enable directory listing |
| `--ssl` | Enable SSL/HTTPS |
| `--ssl-cert` | Path to SSL certificate |
| `--ssl-key` | Path to SSL private key |
| `--fastcgi` | Enable FastCGI mode |
| `--socket` | FastCGI socket path |
| `--library, -l` | Dynamic library path(s) |

---

### 2. server.strada (HTTP Server Core)

**Purpose:** Preforking HTTP server implementation.

**Key data structures:**
```strada
# Server state (hash)
{
    "host"        => "0.0.0.0",
    "port"        => 8080,
    "workers"     => 5,
    "max_requests"=> 1000,
    "timeout"     => 30,
    "router"      => <router reference>,
    "ssl"         => 0,
    "ssl_ctx"     => <SSL context>,
    ...
}
```

**Key functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `Server_new` | `(hash %config) scalar` | Create server from config |
| `Server_run` | `(scalar $server) int` | Start preforking server |
| `Server_run_single` | `(scalar $server) int` | Run single-process (dev mode) |
| `Server_set_router` | `(scalar $server, scalar $router) void` | Attach router |
| `Server_dispatch` | `(scalar $server, scalar $req_ref) scalar` | Route one request (admin, libraries, router) |
| `Server_library_response` | `(scalar $server, scalar $c, str $ret, str $method) hash` | Turn a library handler's result into a response |
| `Server_spawn_worker` | `(scalar $server) int` | Fork a worker process |

**Connection layer:** plain and TLS connections share one path. A conn hash
(`plain_conn` / `tls_conn` / `accept_tls`) is read with `conn_recv` and written
with `conn_send`, both deadline-bounded (`wait_fd` parks in loop mode, polls in
classic mode). `read_request` frames a request (strict `parse_head`,
incremental `decode_chunked_step`, 100-continue); `handle_connection` runs
`dispatch` inside try/catch (a throw = 500, not a dead worker) and
`finish_headers` adds Date / `[headers]` / X-Request-Id. Errors before a full
request is read go through `send_read_error` + `conn_linger_close`.

**Library interface (version 2, `$c->{"_abi"}`).** `cannoli_dispatch($c)`
returns `""` (declined) or a non-empty string (handled, normally
`$c->done()`). `library_response` picks the response: an explicit
`$c->framed_response("RESPONSE:...")`; else `$c`'s own state when the handler
set any (`$c->has_response()`); else the returned string as a body
(JSON if it starts with `{`/`[`, otherwise text/plain, nosniff). A returned
string is never parsed for `STATUS:` / `REDIRECT:` / `RESPONSE:` unless
`app.library_prefixes = 1` (the old interface: user-controlled text could
steer the response). A library that fails to load or init stops startup.

**Watchdog.** `sb_watch` / `touch` / `sb_stuck`: a classic worker is watched
from the start of a handler to its end, a loop worker always (heartbeat
from its watchdog task); the master SIGKILLs a watched worker with no
progress for `server.handler_timeout`. `$c->long_running()` (called by
`ws_accept`) exempts a classic-worker handler. `$c->start_chunked` /
`write_chunk` go through `stream_send` (deadline-bounded `conn_send`).
Keep-alive: `server.keep_alive_requests` per connection, and a classic
worker closes after the response while `others_waiting()`.

**FastCGI mode** (`fastcgi.strada`) shares the scoreboard: workers
`sb_claim`, dispatch runs under `sb_watch`, the FastCGI master kills stuck
workers and rotates logs; paths are normalised; the listener is
non-blocking (two workers waking for one connection must not block in
accept).

**Signal handling:**
- `SIGTERM/SIGINT`: Graceful shutdown (workers SIGKILLed after `shutdown_timeout`)
- `SIGHUP`: Graceful reload (new worker generation; old one SIGKILLed if it outstays `shutdown_timeout`)
- Dead workers are respawned; ones that crash within 2s of starting back off exponentially
- Loop workers rely on Strada dispatching signal handlers inside `Async::Loop`
  (fixed in Strada 3ce3007; older Strada never ran them there)
- systemd: `sd_notify` READY/RELOADING/STOPPING + watchdog pings (see `contrib/cannoli.service`)

---

### 3. router.strada (URL Routing)

**Purpose:** URL pattern matching and request dispatching.

**Route storage:**
```strada
# Router state
{
    "routes"         => [ ... ],      # Array of route entries
    "not_found"      => <handler>,    # 404 handler
    "error_handler"  => <handler>,    # Generic error handler
    "error_handlers" => { 500 => <handler>, ... },  # Per-code handlers
    "middleware"     => [ ... ],      # Global middleware
}

# Route entry
{
    "pattern"  => "/users/([0-9]+)",  # URL pattern
    "method"   => "GET",              # HTTP method (or "ANY")
    "handler"  => <function ref>,     # Handler function
    "regex"    => 1,                  # 1 if regex pattern
    "cannoli"  => 0,                  # 1 if Cannoli-style handler
}
```

**Key functions:**

| Function | Description |
|----------|-------------|
| `Router_new()` | Create new router |
| `Router_get($router, $pattern, $handler)` | Add GET route |
| `Router_post($router, $pattern, $handler)` | Add POST route |
| `Router_put($router, $pattern, $handler)` | Add PUT route |
| `Router_delete_route($router, $pattern, $handler)` | Add DELETE route |
| `Router_any($router, $pattern, $handler)` | Add route for any method |
| `Router_match($router, $method, $path)` | Find matching route |
| `Router_dispatch($router, %req)` | Route and call handler |

**Route patterns:**
- Static: `/users`, `/api/status`
- Regex with captures: `/users/([0-9]+)`, `/files/(.+)`
- Captures accessible via `$req{"captures"}[0]`, etc.

**Handler types:**
1. **Functional** (returns hash): `func handler(hash %req) hash { return Response_json(200, "{}"); }`
2. **Cannoli-style** (receives object): `func handler(scalar $c) hash { $c->render_json({"ok"=>1}); return $c->build_response(); }`

---

### 4. request.strada (Request Parsing)

**Purpose:** Parse raw HTTP requests into structured hash. `path` is
normalised (`normalize_path`: unreserved escapes decoded, dot segments
resolved, slashes merged); the spelling as sent is in `raw_path`.

**Request hash structure:**
```strada
{
    "method"         => "GET",
    "path"           => "/api/users",
    "uri"            => "/api/users?page=1",
    "query_string"   => "page=1",
    "http_version"   => "HTTP/1.1",
    "headers"        => { "content-type" => "application/json", ... },
    "body"           => "request body",
    "params"         => { "page" => "1", ... },
    "captures"       => [ "123" ],        # Regex captures
    "content_type"   => "application/json",
    "content_length" => "42",
    "remote_addr"    => "127.0.0.1",
    "remote_port"    => "54321",
    "files"          => { ... },          # Uploaded files
}
```

**Key functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `Request_parse` | `(str $raw) hash` | Parse raw HTTP request |
| `Request_get_header` | `(hash %req, str $name) str` | Get header (case-insensitive) |
| `Request_has_header` | `(hash %req, str $name) int` | Check header exists |
| `Request_get_param` | `(hash %req, str $name) str` | Get query/form param |
| `Request_get_cookie` | `(hash %req, str $name) str` | Get cookie value |
| `Request_cookies` | `(hash %req) hash` | Get all cookies |
| `Request_is_get` | `(hash %req) int` | Check if GET |
| `Request_is_post` | `(hash %req) int` | Check if POST |
| `Request_is_ajax` | `(hash %req) int` | Check if XHR |
| `Request_accepts_json` | `(hash %req) int` | Check Accept header |
| `Request_json_parse` | `(str $body) scalar` | Parse JSON body |

---

### 5. response.strada (Response Building)

**Purpose:** Build HTTP responses.

**Response hash structure:**
```strada
{
    "status"  => 200,
    "headers" => { "content-type" => "text/html", ... },
    "body"    => "response content",
    "sent"    => 0,  # 1 if already sent (chunked)
}
```

**Key functions:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `Response_new` | `() hash` | Create empty response |
| `Response_text` | `(int $status, str $body) hash` | Plain text |
| `Response_html` | `(int $status, str $body) hash` | HTML |
| `Response_json` | `(int $status, str $body) hash` | JSON |
| `Response_redirect` | `(str $url, int $permanent) hash` | Redirect |
| `Response_not_found` | `() hash` | 404 response |
| `Response_status` | `(hash %res, int $code) void` | Set status |
| `Response_header` | `(hash %res, str $name, str $val) void` | Set header |
| `Response_body` | `(hash %res, str $content) void` | Set body |
| `Response_cache` | `(hash %res, int $seconds) void` | Cache-Control |
| `Response_cors` | `(hash %res, str $origin) void` | CORS headers |
| `Response_set_cookie` | `(hash %res, str $name, str $val, str $opts) void` | Set cookie |
| `Response_build` | `(hash %res) str` | Serialize to HTTP |
| `Response_status_message` | `(int $code) str` | Get status text |
| `Response_html_escape` | `(str $s) str` | Escape HTML |

---

### 6. cannoli_obj.strada (OOP Interface)

**Purpose:** Provides an object-oriented interface for request/response handling, matching the Perl Cannoli API.

**Cannoli object structure:**
```strada
{
    # Request data (prefixed with _)
    "_method"      => "GET",
    "_path"        => "/api/users",
    "_headers"     => { ... },
    "_body"        => "...",
    "_params"      => { ... },
    "_captures"    => [ ... ],
    "_files"       => { ... },

    # Response data (prefixed with _res_)
    "_res_status"       => 200,
    "_res_content_type" => "application/json",
    "_res_headers"      => { ... },
    "_res_body"         => "...",

    # Session, etc.
    "_session"     => <session ref>,
}
```

**Key methods:**

| Category | Methods |
|----------|---------|
| **Request** | `method()`, `path()`, `body()`, `params()`, `param($name)`, `header($name)`, `captures()`, `capture($idx)` |
| **Method checks** | `is_get()`, `is_post()`, `is_put()`, `is_delete()`, `is_ajax()` |
| **Response** | `status($code)`, `content_type($type)`, `set_header($name, $val)`, `write_body($content)` |
| **Rendering** | `render_json($data)`, `render_html($html)`, `render_text($text)`, `redirect($url)`, `error($code, $msg)` |
| **Templates** | `render($template, $vars)`, `render_safe($template, $vars)` |
| **Session** | `session()`, `session_get($key)`, `session_set($key, $val)`, `session_save()` |
| **CORS** | `cors($origin)`, `handle_preflight($origin)` |
| **Auth** | `basic_auth_credentials()`, `basic_auth_user()`, `check_basic_auth($user, $pass)` |
| **Chunked** | `start_chunked()`, `write_chunk($data)`, `end_chunked()` |
| **Build** | `build_response()` → returns response hash |

**Example usage:**
```strada
func handle_api(scalar $c) hash {
    if ($c->is_post()) {
        my str $name = $c->param("name");
        $c->status(201);
        $c->render_json({"created" => $name});
    } else {
        $c->render_json({"users" => []});
    }
    return $c->build_response();
}
```

---

### 7. app.strada (Application Framework)

**Purpose:** High-level API for building applications.

**Key functions:**

| Function | Description |
|----------|-------------|
| `App_new()` | Create new application |
| `App_get($app, $pattern, $handler)` | Add GET route |
| `App_post($app, $pattern, $handler)` | Add POST route |
| `App_put($app, $pattern, $handler)` | Add PUT route |
| `App_delete_route($app, $pattern, $handler)` | Add DELETE route |
| `App_any($app, $pattern, $handler)` | Add any-method route |
| `App_get_c(...)` | Cannoli-style GET route |
| `App_post_c(...)` | Cannoli-style POST route |
| `App_not_found($app, $handler)` | Set 404 handler |
| `App_error($app, $code, $handler)` | Set error handler |
| `App_run($app)` | Start server (command-line `-p`/`-h`/`-w`/`--fastcgi`/`--socket` override the config; `Config::merge_args`) |
| `App_run_dev($app)` | Start in dev mode |

**Example:**
```strada
func main() int {
    my scalar $app = App_new();
    App_get($app, "/", \&handle_home);
    App_get($app, "/api/users/([0-9]+)", \&get_user);
    App_post($app, "/api/users", \&create_user);
    return App_run($app);
}
```

---

### 8. config.strada (Configuration)

**Purpose:** Parse INI-style configuration files.

**Config structure:**
```ini
[server]
host = 0.0.0.0
port = 8080
workers = 5

[ssl]
enabled = true
cert = /path/to/cert.pem
key = /path/to/key.pem

[log]
level = info
```

**Key functions:**

| Function | Description |
|----------|-------------|
| `Config_defaults()` | Get default config hash |
| `Config_parse_file($path)` | Parse config file |
| `Config_get_str(%cfg, $key, $default)` | Get string value |
| `Config_get_int(%cfg, $key, $default)` | Get integer value |
| `Config_get_bool(%cfg, $key, $default)` | Get boolean value |
| `Config_set(%cfg, $key, $value)` | Set value |

**Default config keys:**
- `server.host`, `server.port`, `server.workers`, `server.max_requests`, `server.timeout`
- `server.header_timeout`, `server.body_min_rate`, `server.write_timeout`, `server.keep_alive_timeout`, `server.shutdown_timeout`
- `server.handler_timeout` (stuck-worker kill, 0 = off), `server.keep_alive_requests`
- `server.body_spool_size` / `body_spool_dir` / `body_in_memory`: Content-Length bodies over the size are received into a 0600 temp file (`spool_*` in server.strada), loaded before dispatch unless `body_in_memory = 0` (then `$req{"body_file"}` / `$c->body_file()`); chunked and FastCGI bodies stay in memory
- `app.library_prefixes` (old library return-string interface), `log.rotate_size`, `log.rotate_keep`
- Values may be followed by ` # comment`; a `#` inside a value is kept (`Config::strip_comment`)
- `server.pid_file`, `server.user`, `server.group`, `server.trusted_proxies`, `server.request_id`, `server.tokens`
- `server.health_path`, `server.max_connections_per_ip`, `server.rate_limit`, `server.rate_limit_window`
- `ssl.min_version`, `ssl.ciphers`, `ssl.ciphersuites`; `static.cache_max_age`, `static.gzip`, `static.precompressed`
- `fastcgi.socket` (`unix:/path` or `host:port`), `fastcgi.socket_mode`
- `[headers]` section: default response headers (`headers.X-Content-Type-Options = nosniff`)
- `ssl.enabled`, `ssl.port`, `ssl.cert`, `ssl.key`
- `fastcgi.enabled`, `fastcgi.socket`
- `log.level`, `log.error_file`, `log.access_file`
- `app.document_root`, `app.library`

---

### 9. log.strada (Logging)

**Purpose:** Error and access logging with multiple output targets.

**Log levels:**
- `1` = ERROR
- `2` = WARN
- `3` = INFO (default)
- `4` = DEBUG

**Key functions:**

| Function | Description |
|----------|-------------|
| `Log_init(%config)` | Initialize logging |
| `Log_error($message)` | Log error |
| `Log_warn($message)` | Log warning |
| `Log_info($message)` | Log info |
| `Log_debug($message)` | Log debug |
| `Log_access(...)` | Log access in Combined Log Format |
| `Log_request(%req, %res)` | Log a request |
| `Log_set_rotation($size, $keep)` | Configure log rotation |

**Access log format (Combined Log Format):**
```
127.0.0.1 - - [timestamp] "GET /path HTTP/1.1" 200 1234 "-" "Mozilla/5.0" 15ms
```

---

### 10. session.strada (Session Management)

**Purpose:** File-based session storage.

**Session storage:** `/tmp/cannoli_sessions/sess_<id>`

`Session::save` merges: under a short `flock` on `<dir>/.lock` it rereads
the stored copy and applies only what this request changed (compared with
the `_loaded` snapshot), so overlapping requests do not lose each other's
writes. Expired files are swept from `save` at most every 5 minutes per
directory (`.cleanup` marker).

**Key functions:**

| Function | Description |
|----------|-------------|
| `Session_new()` | Create new session |
| `Session_load($id)` | Load session by ID |
| `Session_save($session)` | Save session to file |
| `Session_destroy($id)` | Delete session |
| `Session_get($session, $key)` | Get value |
| `Session_set($session, $key, $value)` | Set value |
| `Session_has($session, $key)` | Check key exists |
| `Session_id($session)` | Get session ID |
| `Session_cleanup()` | Remove expired sessions |

---

### 11. template.strada (Template Engine)

**Purpose:** Mustache-like template rendering.

**Syntax:**

| Syntax | Description |
|--------|-------------|
| `{{variable}}` | Variable substitution |
| `{{obj.field}}` | Nested field access |
| `{{#if condition}}...{{/if}}` | Conditional |
| `{{#if cond}}...{{else}}...{{/if}}` | If-else |
| `{{#each items}}...{{/each}}` | Loop (fields merged) |
| `{{#each item in items}}...{{/each}}` | Loop with named var |
| `{{@index}}`, `{{@first}}`, `{{@last}}` | Loop metadata |
| `{{#with object}}...{{/with}}` | Change scope |
| `{{#set name = value}}` | Set variable |
| `{{{raw}}}` | Raw output (no escaping) |

**Key functions:**

| Function | Description |
|----------|-------------|
| `Template_init($dir)` | Set template directory |
| `Template_render($name, $vars)` | Render template file |
| `Template_render_string($template, $vars)` | Render string |
| `Template_render_safe($name, $vars)` | Render with HTML escaping |
| `Template_render_with_layout($name, $layout, $vars)` | Render with layout |
| `Template_clear_cache()` | Clear template cache |

---

## Common Patterns

### Creating a Handler (Functional Style)
```strada
func my_handler(hash %req) hash {
    my str $method = $req{"method"};
    my str $path = $req{"path"};
    my str $user_id = $req{"captures"}[0];

    return Response_json(200, "{\"id\":\"" . $user_id . "\"}");
}
```

### Creating a Handler (Cannoli Style)
```strada
func my_handler(scalar $c) hash {
    if ($c->is_get()) {
        $c->render_json({"users" => []});
    } elsif ($c->is_post()) {
        my str $name = $c->param("name");
        $c->status(201);
        $c->render_json({"created" => $name});
    }
    return $c->build_response();
}
```

### Error Handling
```strada
func handle_error(scalar $c) hash {
    my int $code = $c->error_code();
    my str $msg = $c->error_message();
    $c->render_error($code, $msg);
    return $c->build_response();
}

App_error($app, 500, \&handle_error);
```

### Using Sessions
```strada
func handle_login(scalar $c) hash {
    my str $username = $c->param("username");

    $c->session_set("user", $username);
    $c->session_save();

    $c->redirect("/dashboard", 0);
    return $c->build_response();
}
```

### Using Templates
```strada
func handle_page(scalar $c) hash {
    my scalar $vars = {
        "title"  => "Welcome",
        "user"   => { "name" => "Alice", "id" => 42 },
        "items"  => [{"name" => "A"}, {"name" => "B"}],
    };

    $c->render("page.html", $vars);
    return $c->build_response();
}
```

---

## Building and Running

```bash
# Build
make

# Run standalone
./cannoli -p 8080 -w 5

# Run development mode
./cannoli --dev

# Static file server
./cannoli --static ./public --listing

# With SSL
./cannoli --ssl --ssl-cert cert.pem --ssl-key key.pem

# SSL over IPv6 / dual-stack — the TLS listener honors --host just like HTTP
./cannoli --ssl --ssl-cert cert.pem --ssl-key key.pem --host ::    # dual-stack (default)
./cannoli --ssl --ssl-cert cert.pem --ssl-key key.pem --host ::1   # IPv6 loopback only

# FastCGI mode (TCP host:port; loopback by default)
./cannoli --fastcgi --socket 127.0.0.1:9000

# Production: pid file + privilege drop after binding
sudo ./cannoli -c /etc/cannoli.conf --pid-file /run/cannoli.pid --user www-data
```

**TLS implementation.** TLS goes through Strada's `ssl` module
(`lib/ssl.strada`), compiled into the binary and wrapped by `src/tls.strada`
(`Cannoli::TLS`); OpenSSL is linked automatically. There is no separate SSL
library to load (`libstrada_ssl.so` / `STRADA_SSL_LIB` are gone -- Strada no
longer ships that C library). The HTTPS listener binds the configured
`--host` (`::`/dual-stack default, `::1`, `0.0.0.0`, `127.0.0.1`, a literal
address, ...) through `ssl::server_host`, with the same backlog as the HTTP
listener. Accepted connections are non-blocking; handshakes, reads and writes
park the green task in loop workers and use poll(2) in classic workers, all
bounded by the configured timeouts.

---

## Testing

```bash
cd t/
./run_tests.sh
```

Test files:
- `test_config.strada` - Configuration parsing
- `test_router.strada` - URL routing
- `test_request.strada` - Request parsing
- `test_hardening.strada` - Framing/strictness, chunked decoding, cookies, templates, middleware, ranges
- `test_review.strada` / `test_review.sh` - path normalisation, config comments, session merging, template reload, log rotation, shared rate counter / library return values, stuck-worker watchdog, streaming to a stalled client, keep-alive fairness, rejected-request logging
- `test_perl.sh` - the Perl library (skipped until `cd lib/perl && make`)
- `test_hardening.sh` / `test_hardening_loop.sh` - Live timeouts, smuggling inputs, 100-continue, pid file (classic / loop workers)
- `test_tls.sh` - classic+loop x HTTP+HTTPS smoke test (skips without openssl / SSL lib)
- `test_websocket.sh` - WebSockets from a library over ws/wss, classic + loop (echo, idle, close, protocol errors)
- `test_ops.sh` - health, metrics, connection/rate limits, SIGHUP config + cert reload, TLS settings, sd_notify
- `test_fastcgi.sh` - FastCGI over TCP and Unix sockets, keep-conn, shutdown
- `test_fuzz.strada` / `test_fuzz_http.sh` - parser fuzzing / malformed requests against live servers
- `test_privdrop.sh` - privilege drop (needs root; skipped otherwise)
- `tools/soak.sh` - long load test with worker RSS sampling (not part of the suite)

`$c->worker_draining()` (`Cannoli::Server::is_draining`) tells long-lived
handlers (WebSockets, streams) to end their connection when the worker
recycles, reloads or shuts down. Terminale, the web terminal module that
uses it, lives in its own repository (strada-lang/terminale).

**Scoreboard:** `sb_*` functions in `server.strada` keep server-wide counters,
worker slots and a per-address table in one MAP_SHARED mapping created by the
master before fork (atomic ops, no locks); `/__admin/metrics` and the health
check read it. `reload_config` (SIGHUP) re-reads the config file via
`apply_settings`; `src/tls.strada` `configure()` sets chain/min version/
ciphers/ALPN on the ssl module's SSL_CTX (reached through a verified struct
prefix -- the ssl module has no API for it yet).

---

## Key Design Decisions

1. **Preforking model**: Each worker is a separate process, avoiding shared state complexity
2. **Hash-based data**: Requests, responses, and config are all plain hashes for simplicity
3. **Two handler styles**: Functional (returns hash) and OOP (Cannoli object) for flexibility
4. **File-based sessions**: Simple, no external dependencies
5. **Template caching**: Templates cached in memory for performance
6. **No external dependencies**: Pure Strada/C, only links zlib and optionally OpenSSL

---

## Debugging Tips

1. **Enable debug logging**: `./cannoli --debug`
2. **Single-process mode**: `./cannoli --dev` for easier debugging
3. **Dump routes**: `App_dump_routes($app)`
4. **Template debugging**: Use `{{dump varname}}` in templates
5. **Check session files**: Look in `/tmp/cannoli_sessions/`
6. **Access logs**: Show method, path, status, timing

---

## File Size Reference

| File | Lines | Purpose |
|------|-------|---------|
| server.strada | ~3,500 | Preforking HTTP server, connection layer, scoreboard |
| cannoli_obj.strada | ~1,770 | OOP request/response wrapper |
| request.strada | ~1,180 | HTTP request parsing, path normalisation |
| template.strada | ~940 | Template rendering engine |
| router.strada | ~910 | URL routing engine, middleware |
| websocket.strada | ~750 | WebSocket protocol |
| response.strada | ~700 | HTTP response building |
| fastcgi.strada | ~660 | FastCGI protocol |
| main.strada | ~590 | Entry point, CLI parsing |
| static.strada | ~590 | Static file serving |
| log.strada | ~570 | Logging, rotation |
| validation.strada | ~500 | Input validation helpers |
| session.strada | ~480 | Session management |
| config.strada | ~480 | Configuration file parser + validation |
| app.strada | ~260 | Application framework API |
| tls.strada | ~190 | TLS transport over Strada's ssl module |
| mime.strada | ~46 | MIME type mapping |
| **Total** | **~14,100** | |
