#!/bin/sh
# Deterministic, resource-only MCP fixture; all URIs are resolved in this process.
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) result='{"protocolVersion":"2025-11-25","capabilities":{"resources":{}}}' ;;
    *'"method":"resources/list"'*)
      case "$line" in
        *'"cursor":"next"'*) result='{"resources":[]}' ;;
        *) result='{"resources":[{"uri":"memo://stdio","name":"stdio","description":"Fixture memo with the text stdio"}],"nextCursor":"next"}' ;;
      esac ;;
    *'"method":"resources/templates/list"'*) result='{"resourceTemplates":[{"uriTemplate":"memo://{name}","name":"memo","description":"Read a named fixture memo"}]}' ;;
    *'"method":"resources/read"'*)
      case "$line" in
        *'memo://timeout'*) continue ;;
        *'memo://missing'*) printf '{"jsonrpc":"2.0","id":"%s","error":{"code":-32002,"message":"missing"}}\n' "$id"; continue ;;
        *'memo://malformed'*) printf 'invalid JSON\n'; continue ;;
        *'memo://exit'*) exit 7 ;;
        *'memo://oversize'*) awk 'BEGIN { for (i = 0; i < 12582913; i++) printf "x" }'; continue ;;
        *) result='{"contents":[{"uri":"memo://stdio","text":"stdio"}]}' ;;
      esac ;;
    *'"method":"tools/list"'*) exit 7 ;;
    *) continue ;;
  esac
  printf '{"jsonrpc":"2.0","id":"%s","result":%s}\n' "$id" "$result"
done
