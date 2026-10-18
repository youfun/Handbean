#!/bin/sh
# Prompt-only Git askpass. Secrets come from the child environment, not argv.
# Only Username/Password prompts for the expected HTTPS host receive a reply.

prompt=$1
expected=`printf '%s' "${HANDBEAN_GIT_CREDENTIAL_HOST-}" | tr 'A-Z' 'a-z'`

if [ -z "$expected" ]; then
  exit 1
fi

case "$prompt" in
  *[Uu]sername*)
    value=${HANDBEAN_GIT_USERNAME:-x-access-token}
    ;;
  *[Pp]assword*)
    value=${HANDBEAN_GIT_PASSWORD-}
    ;;
  *)
    exit 1
    ;;
esac

case "$prompt" in
  *\'*\'*)
    url=${prompt#*\'}
    url=${url%%\'*}
    ;;
  *)
    exit 1
    ;;
esac

case "$url" in
  [Hh][Tt][Tt][Pp][Ss]://*)
    ;;
  *)
    exit 1
    ;;
esac

hostpath=${url#*://}
case "$hostpath" in
  *@*)
    hostpath=${hostpath#*@}
    ;;
esac

host=$hostpath
case "$host" in
  *[:/?#]*)
    host=${host%%[:/?#]*}
    ;;
esac

host=`printf '%s' "$host" | tr 'A-Z' 'a-z'`

if [ -z "$host" ] || [ "$host" != "$expected" ]; then
  exit 1
fi

printf '%s\n' "$value"
