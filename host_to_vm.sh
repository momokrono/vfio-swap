#!/usr/bin/env bash
# Helper script - basically just 'vfio-swap to-vm'
exec "$(dirname "$0")/vfio-swap" to-vm "$@"
