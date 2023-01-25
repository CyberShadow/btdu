#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"

git -C ~/work/extern/ldc/runtime/druntime diff ldc-v1.30.0..musl32 > docker/ldc-druntime.patch

docker=${DOCKER-docker}

arches=("$@")
if [[ ${#arches[@]} -eq 0 ]]
then
	arches=("$(uname -m)")
	printf 'No architectures specified, building for host architecture.\n'
fi

for arch in "${arches[@]}"
do
	"$docker" build --build-arg BTDU_ARCH="$arch" -t btdu-"$arch" docker
	"$docker" run --rm -v "$(cd .. && pwd)":/btdu --env BTDU_ARCH="$arch" btdu-"$arch" /btdu/ci/build-inside-docker.sh
done
