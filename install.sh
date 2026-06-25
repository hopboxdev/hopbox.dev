#!/bin/sh
# hopbox.dev/install.sh — thin bootstrap.
#
# The canonical server installer lives in the hopbox repo and is the single
# source of truth; this just fetches and runs it so the two can never drift.
#
#   curl -fsSL https://hopbox.dev/install.sh | sudo sh
#
# Overrides (HOPBOX_VERSION, HOPBOX_ZONE, HOPBOX_CADDY, …) pass straight through.
exec sh -c "$(curl -fsSL https://raw.githubusercontent.com/hopboxdev/hopbox/main/deploy/install.sh)"
