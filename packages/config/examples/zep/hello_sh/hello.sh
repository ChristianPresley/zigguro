#!/bin/sh
# hello_sh: a ZEP extension in POSIX sh, to show that any language works.
# It implements Content-Length framing with read/dd/printf and answers
# initialize, command/execute (hello-sh.say), shutdown and exit.
#
# Simplifications: request ids must be integers, and the host writes
# "jsonrpc" then "id" first in each request (zigguro does).

send() {
	body=$1
	len=$(printf '%s' "$body" | wc -c | tr -d ' ')
	printf 'Content-Length: %s\r\n\r\n%s' "$len" "$body"
}

reply() { send "{\"jsonrpc\":\"2.0\",\"id\":$1,\"result\":$2}"; }
fail() { send "{\"jsonrpc\":\"2.0\",\"id\":$1,\"error\":{\"code\":$2,\"message\":\"$3\"}}"; }

while :; do
	len=
	# Headers until the empty line.
	while IFS= read -r line; do
		line=$(printf '%s' "$line" | tr -d '\r')
		[ -z "$line" ] && break
		case $line in
		Content-Length:*) len=$(printf '%s' "${line#Content-Length:}" | tr -d ' ') ;;
		esac
	done || exit 0
	[ -n "$len" ] || exit 0
	body=$(dd bs=1 count="$len" 2>/dev/null)

	method=$(printf '%s' "$body" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
	id=$(printf '%s' "$body" | sed -n 's/^{"jsonrpc":"2.0","id":\([0-9][0-9]*\).*/\1/p')

	case $method in
	initialize)
		reply "$id" '{"protocolVersion":"2026-10","capabilities":{}}'
		;;
	initialized | activate | '$/cancelRequest') ;;
	command/execute)
		case $body in
		*'"id":"hello-sh.say"'*) reply "$id" '"Hello from sh"' ;;
		*) fail "$id" -32601 "unknown command" ;;
		esac
		;;
	shutdown) reply "$id" null ;;
	exit) exit 0 ;;
	*) [ -n "$id" ] && fail "$id" -32601 "method not found" ;;
	esac
done
