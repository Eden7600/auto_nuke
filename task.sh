#!/bin/bash

RANDOM=`printf '%06x\n' $((RANDOM%16777216))`
TASK="`echo "$1_$RANDOM" | tr -c 'A-Za-z0-9\\n' _`"

exec elixir --sname "$TASK" -S mix "$@"
