#!/usr/bin/env bash

exec dub test -c unittest -- -t 1 -v "$@"
