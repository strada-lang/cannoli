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

/* perl_bridge.h - the C interface between cannoli_perl.strada and the
 * embedded Perl interpreter (perl_bridge.c). */
#ifndef CANNOLI_PERL_BRIDGE_H
#define CANNOLI_PERL_BRIDGE_H

#include <stddef.h>

typedef struct { const char *p; size_t n; } pb_str;

typedef struct {
    pb_str method, path, path_info, query_string, body, headers,
           remote_addr, content_type, scheme, request_id;
} pb_request;

int pb_init(void);
int pb_add_inc(const char *path);
int pb_load_cannoli(const char *path);
int pb_use(const char *module);
int pb_do(const char *script);
int pb_set_handler(const char *name);
const char *pb_self_dir(void);
const char *pb_last_error(void);
char *pb_call(const char *handler, const pb_request *rq, size_t *out_len, int *failed);

#endif
