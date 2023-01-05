#!/bin/bash
docker=${DOCKER-podman}
"$docker" run --rm -v "$PWD":/test debian:buster-20210902 /test/build-inside-docker.sh
