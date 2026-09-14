#!/usr/bin/env bash
# Apex Harness - Autonomous AI Agent Runner
APEX_PKG_DIR="/home/leonardo/apex_harness"
export PYTHONPATH="$APEX_PKG_DIR:${PYTHONPATH}"
exec /home/leonardo/.pyenv/versions/3.12.9/bin/python3 -m apex_harness.cli "$@"
