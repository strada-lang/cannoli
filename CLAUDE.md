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
├── src/                          # Core source files (~9,000 lines)
│   ├── main.strada              # Entry point, CLI parsing
│   ├── server.strada            # Preforking HTTP server (~1,100 lines)
│   ├── router.strada            # URL routing engine (~866 lines)
│   ├── request.strada           # HTTP request parsing (~1,055 lines)
│   ├── response.strada          # HTTP response building (~542 lines)
│   ├── cannoli_obj.strada       # OOP request/response wrapper (~1,537 lines)
│   ├── app.strada               # Application framework API (~240 lines)
│   ├── config.strada            # Configuration file parser (~298 lines)
│   ├── log.strada               # Logging system (~498 lines)
│   ├── session.strada           # Session management (~361 lines)
│   ├── template.strada          # Template rendering engine (~884 lines)
│   ├── static.strada            # Static file serving (~192 lines)
│   ├── fastcgi.strada           # FastCGI protocol (~451 lines)
│   ├── validation.strada        # Input validation helpers (~470 lines)
│   └── mime.strada              # MIME type mapping (~44 lines)
├── lib/                          # Extensions
│   ├── compress.strada          # Compression utilities
│   └── perl/                    # Perl integration
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
| `Server_handle_request` | `(scalar $server, int $client_fd, hash %req) void` | Process one request |
| `Server_spawn_worker` | `(scalar $server) int` | Fork a worker process |

**Signal handling:**
- `SIGTERM/SIGINT`: Graceful shutdown
- `SIGHUP`: Graceful reload (restart workers)
- `SIGCHLD`: Worker died, respawn

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

**Purpose:** Parse raw HTTP requests into structured hash.

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
| `App_run($app)` | Start server |
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

# Point Cannoli at a specific SSL library (skips the install/dev path search)
STRADA_SSL_LIB=/path/to/libstrada_ssl.so ./cannoli --ssl --ssl-cert cert.pem --ssl-key key.pem

# FastCGI mode
./cannoli --fastcgi --socket /tmp/cannoli.sock
```

**SSL library resolution.** When `--ssl` is set, the SSL library is `dlopen`'d
from, in order: `$STRADA_SSL_LIB` (if set and non-empty), then
`/usr/local/lib/strada/lib/ssl/libstrada_ssl.so` (installed), then
`../lib/ssl/libstrada_ssl.so` (dev tree). The HTTPS listener binds the
configured `--host` (`::`/dual-stack default, `::1`, `0.0.0.0`, `127.0.0.1`, a
literal address, …) via `strada_ssl_server_host_sv`, matching the plain HTTP
listener; it falls back to a wildcard bind with an older SSL library that
predates the host-aware entry point. IPv6/dual-stack HTTPS requires an SSL
library built with that entry point — rebuild + reinstall `lib/ssl` in the
Strada tree.

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
| server.strada | ~1,100 | Server core |
| request.strada | ~1,055 | Request parsing |
| cannoli_obj.strada | ~1,537 | OOP wrapper |
| router.strada | ~866 | URL routing |
| template.strada | ~884 | Template engine |
| response.strada | ~542 | Response building |
| log.strada | ~498 | Logging |
| validation.strada | ~470 | Validation |
| fastcgi.strada | ~451 | FastCGI |
| session.strada | ~361 | Sessions |
| config.strada | ~298 | Config |
| app.strada | ~240 | App framework |
| main.strada | ~449 | Entry point |
| static.strada | ~192 | Static files |
| **Total** | **~9,000** | |
