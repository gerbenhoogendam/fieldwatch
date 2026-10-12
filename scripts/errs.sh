#!/bin/zsh
# Compact compiler diagnostics: scripts/errs.sh <swift build args...>
swift build "$@" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E "^/.*: (error|warning): " | grep -v "warning:" | sed -E "s|$PWD/||" | sort -u
