#!/bin/sh
set -eu

/usr/bin/systemctl start x11vnc.service >/dev/null 2>&1 || true

exit 0
