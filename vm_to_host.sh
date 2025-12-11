#!/usr/bin/env bash
# Helper script - basically just 'vfio-swap to-host'
exec "$(dirname "$0")/vfio-swap" to-host "$@"
