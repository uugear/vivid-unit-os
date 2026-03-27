#!/bin/sh
# Wrapper to run around LightDM Greeter X sessions.
export GDK_SCALE=2
exec "$@"
