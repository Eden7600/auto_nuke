#!/bin/sh

TASK="`echo "$1" | tr -c 'A-Za-z0-9\\n' _`"

exec elixir --sname "$TASK" -S mix "$@"
