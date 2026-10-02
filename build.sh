#!/bin/sh
# Build norn. Requires the Odin compiler (https://odin-lang.org).
set -e
cd "$(dirname "$0")"
case "$1" in
  test)
    odin test src/manifest -collection:norn=src
    odin test src -collection:norn=src
    ;;
  *)    odin build src -collection:norn=src -out:norn -o:speed ;;
esac
