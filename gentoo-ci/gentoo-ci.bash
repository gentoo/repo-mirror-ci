#!/bin/bash

set -e -x

# SANITY!
export TZ=UTC

cd -- "${SYNC_DIR}"/gentoo
touch -r "${MIRROR_DIR}"/gentoo/metadata/timestamp.chk .git/timestamp
CURRENT_COMMIT=$(git rev-parse --short HEAD)
cd -- "${GENTOO_CI_GIT}"
if [[ -f .last-commit ]]; then
	PREV_COMMIT=$(<.last-commit)
fi

if [[ ${PREV_COMMIT} != ${CURRENT_COMMIT} ]]; then
	# connect early to avoid problems due to init delays
	# note: irk doesn't send empty messages, so we need to fake something
	irk "${IRC_TO}" - <<<$'\0'

	# prepare configroot
	if [[ ! -d ${CONFIG_ROOT_GENTOO_CI} ]]; then
		cp -r -- "${CONFIG_ROOT_MIRROR}" "${CONFIG_ROOT_GENTOO_CI}"
		sed -i -n -e '/\[gentoo\]/,/^$/p' \
			"${CONFIG_ROOT_GENTOO_CI}"/etc/portage/repos.conf
	fi

	export CONFIG_DIR=${CONFIG_ROOT_GENTOO_CI}/etc/portage

	# TODO: setpriv
	cd -- "${MIRROR_DIR}"/gentoo
	sudo -u "${WORKER_USER}" \
		bwrap --bind / / --dev /dev --proc /proc --unshare-all \
		--uid $(id -u "${WORKER_USER}") --gid $(id -g "${WORKER_USER}") \
		time timeout -k 30s "${CI_TIMEOUT}" pkgcheck --config "${CONFIG_DIR}" scan \
		--reporter XmlReporter ${PKGCHECK_OPTIONS} > output.xml.tmp
	# Sort XML for better Git delta compression
	cat output.xml.tmp | xsltproc "${SCRIPT_DIR}"/sort-output.xsl - > output.xml

	"${PKGCHECK_RESULT_PARSER_GIT}"/pkgcheck2borked.py \
		-x "${PKGCHECK_RESULT_PARSER_GIT}"/excludes.json \
		-o borked.list *.xml
	"${PKGCHECK_RESULT_PARSER_GIT}"/pkgcheck2borked.py \
		-x "${PKGCHECK_RESULT_PARSER_GIT}"/excludes.json \
		-s -w -o warning.list *.xml

	git add -- *.xml
	git diff --cached --quiet --exit-code || git commit -a -m "$(date -u --date="@$(cd -- "${SYNC_DIR}"/gentoo; git log --pretty="%ct" -1)" "+%Y-%m-%d %H:%M:%S UTC")"
	git push
	curl "https://qa-reports-cdn-origin.gentoo.org/cgi-bin/trigger-pull.cgi?gentoo-ci" || :
	"${SCRIPT_DIR}"/gentoo-ci/report-borked.bash "${PREV_COMMIT}" "${CURRENT_COMMIT}"
	echo "${CURRENT_COMMIT}" > .last-commit

	if [[ ! -s ${GENTOO_CI_GIT}/borked.list ]]; then
		# no failures? push to the stable branch!
		cd -- "${MIRROR_DIR}"/gentoo
		git fetch --all
		git push origin master:stable
	fi
fi
