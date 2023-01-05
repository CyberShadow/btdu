cd "$(dirname "$0")"

docker=${DOCKER-docker}

arches=("$@")
if [[ ${#arches[@]} -eq 0 ]]
then
	arches=("$(uname -m)")
fi

for arch in "${arches[@]}"
do
	"$docker" build --build-arg BTDU_ARCH="$arch" --iidfile=iid docker
	"$docker" run --timeout=30 --rm -v "$(cd .. && pwd)":/btdu --env BTDU_ARCH="$arch" "$(cat iid)" /btdu/ci/build-inside-docker.sh
done
