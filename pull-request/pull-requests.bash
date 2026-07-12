#!/bin/bash

set -e -x

# SANITY!
export TZ=UTC

sync=${SYNC_DIR}/gentoo
mirror=${MIRROR_DIR}/gentoo
gentooci=${GENTOO_CI_GIT}
pull=${PULL_REQUEST_DIR}

if [[ -s ${pull}/current-pr ]]; then
	pr=$(<"${pull}"/current-pr)
	forge="${pr%/*}"
	prid="${pr#*/}"
	cd -- "${sync}"
	case ${forge} in
		github) prlink="${PULL_REQUEST_REPO}/pull/${prid}";;
		codeberg) prlink="https://codeberg.org/${CODEBERG_REPO}/pulls/${prid}";;
		*) echo "unknown forge ${forge}"; exit 1;;
	esac
	"${SCRIPT_DIR}"/pull-request/set-pull-request-status.py "${pr}" error \
		"QA checks crashed. Please rebase and check profile changes for syntax errors."
	sendmail "${CRONJOB_ADMIN_MAIL}" <<-EOF
		Subject: Pull request crash: ${pr}
		To: <${CRONJOB_ADMIN_MAIL}>
		Content-Type: text/plain; charset=utf8

		It seems that pull request check for ${pr} crashed [1].

		[1]:${prlink}
	EOF
	rm -f -- "${pull}"/current-pr
fi

cd -- "${mirror}"
git pull

# check if we have anything to process
mkdir -p -- "${pull}"
pr=$( "${SCRIPT_DIR}"/pull-request/scan-pull-requests.py )
forge="${pr%/*}"
prid="${pr#*/}"

if [[ -n ${pr} ]]; then
	echo "${pr}" > "${pull}"/current-pr

	cd -- "${sync}"
	if ! git remote | grep -q codeberg; then
		git remote add codeberg "https://codeberg.org/${CODEBERG_REPO}"
	fi
	ref=refs/pull/${pr}

	case ${forge} in
		github) remote="origin";;
		codeberg) remote="codeberg";;
		*) echo "unknown forge ${forge}"; exit 1;;
	esac
	git fetch -f "${remote}" "refs/pull/${prid}/head:${ref}"
	hash=$(git rev-parse "${ref}")

	sudo -u "${WORKER_USER}" \
		bwrap --bind / / --dev /dev --proc /proc --unshare-all \
		"${SCRIPT_DIR}"/pull-request/pull-requests-worker.bash \
		"${pr}"

	cd -- "${gentooci}"
	git fetch "${WORKER_DIR}"/gentoo-ci "pull-${forge}-${prid}"
	pr_hash=$(git rev-parse --short FETCH_HEAD)
	git push -f origin "FETCH_HEAD:refs/heads/pull-${forge}-${prid}"

	curl "https://qa-reports-cdn-origin.gentoo.org/cgi-bin/trigger-pull.cgi?gentoo-ci" || :
	"${SCRIPT_DIR}"/pull-request/report-pull-request.py "${forge}" "${prid}" "${pr_hash}" \
		"${WORKER_DIR}"/gentoo-ci/borked.list "${WORKER_DIR}"/tmp/.pre-merge.borked "${hash}"

	rm -f -- "${pull}"/current-pr
fi
