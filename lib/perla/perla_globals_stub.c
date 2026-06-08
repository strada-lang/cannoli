/* perla_globals_stub.c
 *
 * Every Perla-compiled main program defines a set of "special" globals
 * (perla_eval_error, perla_dollar_underscore, v_ARGV, v_ENV, ...) that
 * precompiled .pm.o / .pm.so files reference as `extern`. When we load
 * such a .pm.so from our bridge shared library (cannoli_perla.so), the
 * dynamic linker needs these symbols to exist globally. Normally the
 * main exe provides them. For the bridge-.so use case, we provide them
 * here.
 *
 * The list was cribbed from the header block of a freshly generated
 * `perla -c` output (the `Perl special variables (global for
 * precompiled module linking)` section). If Perla grows more globals,
 * add them here.
 */

#include "strada_runtime.h"

/* Perl special variables */
StradaValue *perla_eval_error = NULL;
StradaValue *perla_dollar_underscore = NULL;
StradaValue *perla_irs = NULL;   /* $/ */
StradaValue *perla_ors = NULL;   /* $\ */
StradaValue *perla_ofs = NULL;   /* $, */
int __perla_autoflush = 0;       /* $| */
int __perla_want_list = 0;
StradaValue *perla_at_ = NULL;   /* @_ fallback */
StradaValue *perla_dollar_zero = NULL; /* $0 */

/* Package globals typically provided by main.c */
StradaValue *v_STDIN = NULL;
StradaValue *v_STDOUT = NULL;
StradaValue *v_STDERR = NULL;
StradaValue *v_ARGV = NULL;
StradaValue *v_ENV = NULL;
StradaValue *v_ISA = NULL;
StradaValue *v__ = NULL;
StradaValue *v_SIG = NULL;
StradaValue *v_a = NULL;
StradaValue *v_b = NULL;
StradaValue *v_INC = NULL;
StradaValue *v__caret_W = NULL;  /* $^W */
StradaValue *v__caret_O = NULL;  /* $^O */
StradaValue *v__rbrack_ = NULL;  /* $] */
StradaValue *v__caret_V = NULL;  /* $^V */
StradaValue *v__caret_X = NULL;  /* $^X */

/* Closure cell + sort block scratch that any non-trivial Perla-compiled
 * code uses. 64 is the size baked into the Perla codegen. */
StradaValue *__perla_sort_ctx[16] = {0};
StradaValue **__perla_cell[64] = {0};
