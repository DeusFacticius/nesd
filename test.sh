#!/usr/bin/env bash

exec dub test -- -t 1 -v "$@"
