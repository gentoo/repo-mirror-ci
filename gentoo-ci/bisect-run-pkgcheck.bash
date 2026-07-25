#!/bin/bash

set -e -x

trap 'exit 255' EXIT

flag=${1}
shift

export HOME=${BISECT_TMP}
current_commit=$(git rev-parse BISECT_HEAD)

if [[ -s ${BISECT_TMP}/.bisect.cache.${flag} ]]; then
	while read -a cline; do
		if [[ ${cline[0]} == ${current_commit} ]]; then
			ret=0
			for p in "${cline[@]:1}"; do
				if [[ ${p} == ${1} ]]; then
					ret=1
					break
				fi
			done
			trap '' EXIT
			exit "${ret}"
		fi
	done <"${BISECT_TMP}/.bisect.cache.${flag}"
fi

git checkout -q "${current_commit}"

# we always check multiple packages and cache the result to avoid
# re-checking the same commits in next bisect
# however, we only return result for the first one

# TODO: setpriv
sudo -u "${WORKER_USER}" \
	bwrap --bind / / --dev /dev --proc /proc --unshare-all \
	--uid $(id -u "${WORKER_USER}") --gid $(id -g "${WORKER_USER}") \
	pkgcheck --config "${CONFIG_DIR}" scan --reporter XmlReporter "${@}" \
	--glsa-dir "${MIRROR_DIR}"/gentoo/metadata/glsa \
	${PKGCHECK_BISECT_OPTIONS} \
	> "${BISECT_TMP}/.bisect.tmp.xml"

"${PKGCHECK_RESULT_PARSER_GIT}"/pkgcheck2borked.py \
	-x "${PKGCHECK_RESULT_PARSER_GIT}"/excludes.json \
	--output "${BISECT_TMP}/.bisect.tmp.borked" \
	"${BISECT_TMP}/.bisect.tmp.xml"

"${PKGCHECK_RESULT_PARSER_GIT}"/pkgcheck2borked.py \
	-x "${PKGCHECK_RESULT_PARSER_GIT}"/excludes.json \
	-s -w --output "${BISECT_TMP}/.bisect.tmp.warning" \
	"${BISECT_TMP}/.bisect.tmp.xml"

borked_pkgs=()
while read l; do
	[[ ${l} ]] && borked_pkgs+=( "${l}" )
done <"${BISECT_TMP}/.bisect.tmp.borked"

warning_pkgs=()
while read l; do
	[[ ${l} ]] && warning_pkgs+=( "${l}" )
done <"${BISECT_TMP}/.bisect.tmp.warning"

echo "${current_commit} ${borked_pkgs[*]}" >> "${BISECT_TMP}/.bisect.cache.e"
echo "${current_commit} ${warning_pkgs[*]}" >> "${BISECT_TMP}/.bisect.cache.w"

[[ ${flag} == w ]] && borked_pkgs=( "${warning_pkgs[@]}" )

ret=0
for p in "${borked_pkgs[@]}"; do
	if [[ ${1} == ${p} ]]; then
		ret=1
		break
	fi
done

trap '' EXIT
exit "${ret}"
