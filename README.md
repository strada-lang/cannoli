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
./cannoli --fastcgi --socket /tmp/cannoli.sock
```

nginx configuration:
```nginx
location / {
    fastcgi_pass unix:/tmp/cannoli.sock;
    include fastcgi_params;
}
```

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
max_requests = 1000
timeout = 30

[ssl]
enabled = true
port = 443
cert = /path/to/cert.pem
key = /path/to/key.pem

[fastcgi]
enabled = false
socket = /tmp/cannoli.sock

[static]
root = ./public
listing = true

[app]
library = lib1.so, lib2.so

[log]
level = info
```

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
- `api_example.strada` - REST API example

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
- Graceful shutdown via SIGTERM/SIGINT
- Graceful reload via SIGHUP

## License

GNU General Public License v2. See [LICENSE](LICENSE) for details.

Part of the [Strada](https://github.com/strada-lang/strada) project.
