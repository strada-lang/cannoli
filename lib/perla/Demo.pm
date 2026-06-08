package Demo;

use strict;
use warnings;

# Minimal handler — ignores $c for now, just returns a fixed response.
# cannoli_perla_demo.so will be dlopen'd; its `perla_sub_Demo_hello`
# entry is what cannoli_perla's dispatch calls.
sub hello {
    return "Hello from a Perla-compiled handler!\n";
}

1;
