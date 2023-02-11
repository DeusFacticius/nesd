#!/usr/bin/env bash

if [[ $# -lt 1 ]]; then
	ARGS=("nestest.nes")
else
	ARGS=("${@}")
fi

exec dub run -b debug -d verbose -- "${ARGS[@]}"

