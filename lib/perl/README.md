# Cannoli Perl library

Runs Perl request handlers inside Cannoli through an embedded interpreter.

## Building

```bash
cd lib/perl
make            # builds cannoli_perl.so
make test       # runs t/test_perl.sh against ../../cannoli
```

Needs the Perl development headers (`libperl-dev` on Debian/Ubuntu). The
Makefile embeds `/opt/bzperl/bin/perl` when it exists, otherwise the `perl`
on `PATH`; `make PERL=/path/to/perl` picks another. The library is one file:
`cannoli_perl.so` contains both the Strada side (`cannoli_perl.strada`) and
the interpreter bridge (`perl_bridge.c`). `Cannoli.pm` is loaded from the
directory the library is in.

## Usage

```bash
cannoli --library "./lib/perl/cannoli_perl.so:script=/path/to/app.pl;handler=MyApp::handle"
cannoli --library "./lib/perl/cannoli_perl.so:lib=./lib;use=MyApp;handler=MyApp::dispatch"
```

| Option | Description |
|--------|-------------|
| `handler=Sub::Name` | Perl sub called for each request (required) |
| `script=/path/to.pl` | Script to load at startup |
| `lib=/path` | Added to the front of `@INC` (may be repeated) |
| `use=Module::Name` | Module to load at startup (may be repeated) |
| `cannoli_pm=/path/Cannoli.pm` | Use this `Cannoli.pm` instead of the one next to the library |

A script that cannot be read or compiled, a module that fails to load, or a
handler that is not defined stops Cannoli from starting, with the Perl error.

## Handlers

The handler receives a `Cannoli` object and builds the response on it. Its
return value is not used.

```perl
package MyApp;
use strict; use warnings;

sub handle {
    my ($c) = @_;
    if ($c->path eq '/hello') {
        return $c->render_text('Hello, ' . ($c->param('name') // 'world'));
    }
    if ($c->is_post && $c->path eq '/api/items') {
        my $item = $c->json;                       # parsed JSON body
        return $c->status(201)->render_json({ created => $item });
    }
    return;                                        # nothing set: declined (404)
}

sub child_init { }     # optional, see "Processes" below
1;
```

Request: `method`, `path`, `path_info`, `query_string`, `body`, `param($name)`,
`params`, `header($name)`, `headers`, `json`, `remote_addr`, `scheme`,
`is_secure`, `request_id`, `is_get` / `is_post` / ...

Response: `status($code)`, `content_type($type)`, `set_header($name, $value)`,
`add_header($name, $value)` (keeps earlier values), `set_cookie($name, $value,
%opts)` (one `Set-Cookie` per call), `write($data)`, `render_json($data)`,
`render_text($text)`, `render_html($html)`, `redirect($url, $code)`,
`error($code, $message)`, `sendfile($path)`, `decline`.

What a handler should know:

- **Declining.** A handler that sets nothing on `$c` declines the request
  (the next library, or Cannoli's 404). Setting anything, including only
  `status(200)`, is a response. `$c->decline` withdraws what was set.
- **Bytes.** The request body arrives as bytes exactly as sent, NUL bytes
  included. A response body that is a byte string goes out unchanged; one
  with wide characters goes out as UTF-8.
- **`die`.** The client gets a plain 500. The message goes to Cannoli's
  error log with the request ID, never to the client.
- **`exit`.** Ends the request with the response built so far. It does not
  end the worker process. (As with mod_perl, an `eval {}` around the call
  catches it.)
- **Header values** containing CR, LF or NUL are dropped.

## Processes

The interpreter starts, and the script is compiled, once in the master
process; workers are forked from it. In each worker, before its first
request, the library calls `srand()` (so workers do not share one random
sequence) and then `child_init()` in the handler's package if it is defined.
Open database connections and other handles there, not at file scope: a
handle opened at load time is shared by every worker.

A handler runs to completion on its worker; with `--loop-workers` it blocks
that worker's other connections while it runs. Classic workers (the
default) are the better fit for Perl applications.
