#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"

docker build -t btdu docker
docker run --rm -v "$(cd .. && pwd)":/btdu btdu /btdu/ci/build-inside-docker.sh
