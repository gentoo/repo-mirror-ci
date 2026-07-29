#!/bin/bash

exec 3>&1
exec 1>&2

set -e -x

bad=${1}
good=${2}
flag=${3}
shift 3

pkgs=()
for p; do
	[[ ${p} == -WARN- ]] && continue
	pkgs+=( "${p}" )
done

cd -- "${SYNC_DIR}/gentoo"
trap "git bisect reset; git checkout -q master" EXIT

git bisect start --no-checkout "${bad}" "${good}^"
git bisect run "${SCRIPT_DIR}"/gentoo-ci/bisect-run-pkgcheck.bash "${flag}" "${pkgs[@]}" "${SYNC_DIR}"
git rev-parse --short bisect/bad >&3
