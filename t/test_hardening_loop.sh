#!/bin/bash
# Same hardening checks with event-loop workers.
EXTRA="loop_workers = 1" exec bash "$(dirname "$0")/test_hardening.sh"
