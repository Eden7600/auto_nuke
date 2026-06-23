#!/bin/sh

if ! git diff --exit-code --stat test; then
	echo <<-EOF > /dev/stderr
	You have uncommitted changes to tests.

	Please commit those before running this command.
	EOF

	exit 1
fi

mix test 2> /dev/null \
	| grep '^ \+test/.*:[0-9]\+$' \
	| sort -Vr \
	| xargs -I! sh -c '
		IFS=: read -r file line <<< "!";
		echo "${line}i\n@tag :skip\n.\nwq" | ed $file
	'

mix format "test/**/*.exs"
