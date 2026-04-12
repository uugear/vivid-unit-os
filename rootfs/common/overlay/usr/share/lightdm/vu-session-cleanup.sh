#!/bin/sh
set -eu

/usr/bin/systemctl stop x11vnc.service >/dev/null 2>&1 || true

exit 0
