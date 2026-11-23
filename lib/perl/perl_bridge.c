/*
 This file is part of the Strada Language (https://github.com/mjflick/strada-lang).
 Copyright (c) 2026 Michael J. Flickinger
 
 This program is free software: you can redistribute it and/or modify  
 it under the terms of the GNU General Public License as published by  
 the Free Software Foundation, version 2.

 This program is distributed in the hope that it will be useful, but 
 WITHOUT ANY WARRANTY; without even the implied warranty of 
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU 
 General Public License for more details.

 You should have received a copy of the GNU General Public License 
 along with this program. If not, see <http://www.gnu.org/licenses/>.
*/

/*
 * perl_bridge.c - embeds a Perl interpreter for the Cannoli Perl library.
 *
 * Plain C: it knows nothing about Strada values. cannoli_perl.strada hands
 * it (pointer, length) pairs and gets a malloc'd buffer with a length back,
 * so request bodies and responses are binary-safe in both directions and
 * nothing is left allocated after a request.
 *
 * Linked into cannoli_perl.so together with the Strada side.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <libgen.h>

#include <EXTERN.h>
#include <perl.h>

#include "perl_bridge.h"

static PerlInterpreter *my_perl = NULL;
static pid_t pb_owner_pid = 0;      /* process the interpreter last ran in */
static char pb_err[1024] = "";

const char *pb_last_error(void) { return pb_err; }

static void pb_set_err(const char *what) {
    const char *detail = (my_perl && SvTRUE(ERRSV)) ? SvPV_nolen(ERRSV) : "";
    snprintf(pb_err, sizeof(pb_err), "%s%s%s", what, *detail ? ": " : "", detail);
    size_t n = strlen(pb_err);
    while (n > 0 && (pb_err[n - 1] == '\n' || pb_err[n - 1] == '\r')) pb_err[--n] = '\0';
}

/* xs_init registers DynaLoader, without which the embedded interpreter
 * cannot load any XS module (IO, Cwd, DBI, ...). Standard perlembed. */
EXTERN_C void boot_DynaLoader(pTHX_ CV *cv);

static void xs_init(pTHX) {
    static const char file[] = __FILE__;
    dXSUB_SYS;
    PERL_UNUSED_CONTEXT;
    newXS("DynaLoader::boot_DynaLoader", boot_DynaLoader, file);
}

/* Directory of the shared object this code lives in ("" if unknown). */
const char *pb_self_dir(void) {
    static char dir[4096] = "";
    if (!dir[0]) {
        Dl_info info;
        if (dladdr((void *)pb_self_dir, &info) && info.dli_fname) {
            char tmp[4096];
            char *real = realpath(info.dli_fname, NULL);
            snprintf(tmp, sizeof(tmp), "%s", real ? real : info.dli_fname);
            free(real);
            snprintf(dir, sizeof(dir), "%s", dirname(tmp));
        }
    }
    return dir;
}

/* Code run once, before any application code is compiled:
 *  - exit() inside a handler must end the request, not the worker process
 *    (and with it every other request that worker would have served), so
 *    CORE::GLOBAL::exit throws an exception the bridge recognises. In any
 *    other process -- a child the handler forked -- exit() must really
 *    exit: unwinding there would return the child into the worker's
 *    request loop as a second server on the same sockets.
 *  - Cannoli::Bridge::load runs a script file by path (the path arrives in
 *    a variable; it is never pasted into Perl source). */
static const char pb_boot[] =
    "package Cannoli::Exit; sub code { $_[0]{code} }\n"
    "package Cannoli::Bridge;\n"
    "our ($arg, $handler, $pid);\n"
    "BEGIN { $pid = $$; *CORE::GLOBAL::exit = sub {\n"
    "    CORE::exit(@_ ? $_[0] : 0) if $$ != $pid;\n"
    "    die bless({ code => (@_ ? $_[0] : 0) }, 'Cannoli::Exit') }; }\n"
    "sub load {\n"
    "    my $p = $arg;\n"
    "    die \"cannot read $p\\n\" unless -f $p && -r _;\n"
    "    $p = \"./$p\" unless $p =~ m{^\\.{0,2}/};\n"
    "    do $p;\n"
    "    die $@ if $@;\n"
    "    1;\n"
    "}\n"
    "sub req { my $p = $arg; require $p; 1 }\n"
    "sub child {\n"
    "    $pid = $$;\n"
    "    srand();\n"
    "    (my $pkg = $handler) =~ s/::[^:]+$//;\n"
    "    if (my $hook = $pkg->can('child_init')) { $hook->(); }\n"
    "    1;\n"
    "}\n"
    "1;\n";

int pb_init(void) {
    if (my_perl) return 1;

    /* XS modules that DynaLoader dlopens later resolve the interpreter's
     * symbols (PL_*, Perl_*) from the global scope, but libperl came in as
     * a dependency of this library, in local scope. Re-open the very file
     * that is already loaded with RTLD_GLOBAL to promote it. */
    Dl_info info;
    if (dladdr((void *)perl_alloc, &info) && info.dli_fname) {
        dlopen(info.dli_fname, RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
    }

    int argc = 3;
    static char *argv[] = { "cannoli", "-e", "0", NULL };
    char **argv_ptr = argv;
    extern char **environ;
    char **env_ptr = environ;

    PERL_SYS_INIT3(&argc, &argv_ptr, &env_ptr);
    my_perl = perl_alloc();
    if (!my_perl) { snprintf(pb_err, sizeof(pb_err), "could not allocate a Perl interpreter"); return 0; }
    perl_construct(my_perl);
    PL_exit_flags |= PERL_EXIT_DESTRUCT_END;

    if (perl_parse(my_perl, xs_init, argc, argv, NULL) != 0) {
        perl_destruct(my_perl);
        perl_free(my_perl);
        my_perl = NULL;
        snprintf(pb_err, sizeof(pb_err), "could not start the Perl interpreter");
        return 0;
    }
    perl_run(my_perl);
    pb_owner_pid = getpid();

    eval_pv(pb_boot, FALSE);
    if (SvTRUE(ERRSV)) { pb_set_err("bridge setup failed"); return 0; }
    return 1;
}

int pb_add_inc(const char *path) {
    if (!my_perl || !path || !*path) return 0;
    AV *inc = GvAVn(PL_incgv);
    if (!inc) return 0;
    av_unshift(inc, 1);
    av_store(inc, 0, newSVpv(path, 0));
    return 1;
}

/* Call Cannoli::Bridge::<fn>() with $Cannoli::Bridge::arg = arg. */
static int pb_call_boot(const char *fn, const char *arg, const char *what) {
    if (!my_perl) return 0;
    if (arg) sv_setpv(get_sv("Cannoli::Bridge::arg", GV_ADD), arg);
    char name[64];
    snprintf(name, sizeof(name), "Cannoli::Bridge::%s", fn);
    dSP;
    ENTER; SAVETMPS;
    PUSHMARK(SP);
    PUTBACK;
    int count = call_pv(name, G_SCALAR | G_EVAL);
    SPAGAIN;
    if (count > 0) (void)POPs;
    int ok = !SvTRUE(ERRSV);
    if (!ok) pb_set_err(what);
    PUTBACK;
    FREETMPS; LEAVE;
    return ok;
}

/* Load Cannoli.pm from an explicit path, or from @INC when path is NULL. */
int pb_load_cannoli(const char *path) {
    if (!my_perl) return 0;
    if (path && *path) return pb_call_boot("req", path, "could not load Cannoli.pm");
    eval_pv("require Cannoli; 1;", FALSE);
    if (SvTRUE(ERRSV)) { pb_set_err("could not load Cannoli.pm"); return 0; }
    return 1;
}

static int pb_is_module_name(const char *s) {
    if (!s || !*s) return 0;
    for (const char *p = s; *p; p++) {
        char ch = *p;
        int word = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_' || (p > s && ch >= '0' && ch <= '9');
        if (word) continue;
        if (ch == ':' && p[1] == ':' && p > s && p[2] != '\0' && p[2] != ':') { p++; continue; }
        return 0;
    }
    return 1;
}

int pb_use(const char *module) {
    if (!my_perl) return 0;
    if (!pb_is_module_name(module)) {
        snprintf(pb_err, sizeof(pb_err), "'%.200s' is not a module name", module ? module : "");
        return 0;
    }
    char code[512];
    snprintf(code, sizeof(code), "use %s; 1;", module);
    eval_pv(code, FALSE);
    if (SvTRUE(ERRSV)) { pb_set_err("use failed"); return 0; }
    return 1;
}

int pb_do(const char *script) {
    if (!script || !*script) return 0;
    return pb_call_boot("load", script, "could not load the script");
}

/* The handler must exist once everything is loaded: a typo is a startup
 * error, not a 500 on every request. */
int pb_set_handler(const char *name) {
    if (!my_perl || !name || !*name) return 0;
    if (!get_cv(name, 0)) {
        snprintf(pb_err, sizeof(pb_err), "handler %.200s is not defined", name);
        return 0;
    }
    sv_setpv(get_sv("Cannoli::Bridge::handler", GV_ADD), name);
    return 1;
}

/* "name: value\r\n" lines -> { lowercased-name => value } */
static HV *pb_headers_hv(pTHX_ pb_str h) {
    HV *hv = newHV();
    const char *p = h.p, *end = h.p + h.n;
    while (p < end) {
        const char *eol = memchr(p, '\n', (size_t)(end - p));
        if (!eol) eol = end;
        const char *colon = memchr(p, ':', (size_t)(eol - p));
        if (colon && colon > p) {
            size_t name_len = (size_t)(colon - p);
            char *name = malloc(name_len + 1);
            if (name) {
                for (size_t i = 0; i < name_len; i++) name[i] = (p[i] >= 'A' && p[i] <= 'Z') ? (char)(p[i] + 32) : p[i];
                name[name_len] = '\0';
                const char *v = colon + 1;
                while (v < eol && (*v == ' ' || *v == '\t')) v++;
                const char *ve = eol;
                while (ve > v && (ve[-1] == '\r' || ve[-1] == ' ' || ve[-1] == '\t')) ve--;
                (void)hv_store(hv, name, (I32)name_len, newSVpvn(v, (STRLEN)(ve - v)), 0);
                free(name);
            }
        }
        p = eol < end ? eol + 1 : end;
    }
    return hv;
}

static void pb_push_pair(pTHX_ SV ***spp, const char *key, pb_str v) {
    SV **sp = *spp;
    XPUSHs(sv_2mortal(newSVpv(key, 0)));
    XPUSHs(sv_2mortal(newSVpvn(v.p ? v.p : "", v.p ? v.n : 0)));
    *spp = sp;
}

/* 1 if $@ is the exception thrown by the exit() override. */
static int pb_is_exit(pTHX) {
    SV *err = ERRSV;
    return SvROK(err) && sv_derived_from(err, "Cannoli::Exit");
}

static char *pb_dup_err(pTHX_ size_t *out_len) {
    STRLEN len;
    const char *err = SvPV(ERRSV, len);
    while (len > 0 && (err[len - 1] == '\n' || err[len - 1] == '\r')) len--;
    char *copy = malloc(len + 1);
    if (!copy) { *out_len = 0; return NULL; }
    memcpy(copy, err, len);
    copy[len] = '\0';
    *out_len = len;
    return copy;
}

/*
 * Run the handler for one request.
 *
 * Returns a malloc'd buffer of *out_len bytes (the caller frees it):
 *   *failed == 0: the framed response built by Cannoli.pm, or an empty
 *                 buffer when the handler declined the request
 *   *failed == 1: the handler (or Cannoli.pm) died; the buffer is the
 *                 error text, for the log -- never for the client
 */
char *pb_call(const char *handler, const pb_request *rq, size_t *out_len, int *failed) {
    *out_len = 0;
    *failed = 0;
    if (!my_perl || !handler) return NULL;

    /* First request in a forked worker: the interpreter was set up in the
     * master, so every worker starts with the same random seed (and the
     * same open handles). Reseed, and let the application reconnect. */
    if (getpid() != pb_owner_pid) {
        pb_owner_pid = getpid();
        if (!pb_call_boot("child", NULL, "child_init failed")) {
            fprintf(stderr, "cannoli_perl: %s\n", pb_err);
        }
    }

    dSP;
    ENTER;
    SAVETMPS;

    /* Cannoli->new(...) */
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVpv("Cannoli", 0)));
    pb_push_pair(aTHX_ &sp, "method", rq->method);
    pb_push_pair(aTHX_ &sp, "path", rq->path);
    pb_push_pair(aTHX_ &sp, "path_info", rq->path_info);
    pb_push_pair(aTHX_ &sp, "query_string", rq->query_string);
    pb_push_pair(aTHX_ &sp, "body", rq->body);
    pb_push_pair(aTHX_ &sp, "remote_addr", rq->remote_addr);
    pb_push_pair(aTHX_ &sp, "content_type", rq->content_type);
    pb_push_pair(aTHX_ &sp, "scheme", rq->scheme);
    pb_push_pair(aTHX_ &sp, "request_id", rq->request_id);
    XPUSHs(sv_2mortal(newSVpv("headers", 0)));
    XPUSHs(sv_2mortal(newRV_noinc((SV *)pb_headers_hv(aTHX_ rq->headers))));
    PUTBACK;

    int count = call_method("new", G_SCALAR | G_EVAL);
    SPAGAIN;
    SV *obj = NULL;
    if (count > 0) {
        SV *top = POPs;
        if (!SvTRUE(ERRSV) && SvROK(top)) obj = SvREFCNT_inc(top);
    }
    PUTBACK;

    char *result = NULL;
    if (!obj) {
        *failed = 1;
        if (SvTRUE(ERRSV)) result = pb_dup_err(aTHX_ out_len);
        else { result = strdup("Cannoli->new did not return an object"); *out_len = result ? strlen(result) : 0; }
        FREETMPS; LEAVE;
        return result;
    }

    /* handler($c) -- its return value is not used */
    PUSHMARK(SP);
    XPUSHs(obj);
    PUTBACK;
    count = call_pv(handler, G_SCALAR | G_EVAL);
    SPAGAIN;
    if (count > 0) (void)POPs;
    PUTBACK;

    if (SvTRUE(ERRSV) && !pb_is_exit(aTHX)) {
        *failed = 1;
        result = pb_dup_err(aTHX_ out_len);
    } else {
        /* $c->_build_response() */
        PUSHMARK(SP);
        XPUSHs(obj);
        PUTBACK;
        count = call_method("_build_response", G_SCALAR | G_EVAL);
        SPAGAIN;
        SV *ret = count > 0 ? POPs : NULL;
        if (SvTRUE(ERRSV)) {
            *failed = 1;
            result = pb_dup_err(aTHX_ out_len);
        } else if (ret && SvOK(ret)) {
            STRLEN len;
            const char *str = SvPVbyte(ret, len);
            result = malloc(len + 1);
            if (result) {
                memcpy(result, str, len);
                result[len] = '\0';
                *out_len = len;
            }
        }
        PUTBACK;
    }

    SvREFCNT_dec(obj);
    FREETMPS;
    LEAVE;
    return result;
}
