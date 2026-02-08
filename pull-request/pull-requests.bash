#!/bin/bash

set -e -x

# SANITY!
export TZ=UTC

sync=${SYNC_DIR}/gentoo
mirror=${MIRROR_DIR}/gentoo
gentooci=${GENTOO_CI_GIT}
pull=${PULL_REQUEST_DIR}

if [[ -s ${pull}/current-pr ]]; then
	iid=$(<"${pull}"/current-pr)
	cd -- "${sync}"
	hash=$(git rev-parse "refs/pull/${iid}")
	"${SCRIPT_DIR}"/pull-request/set-pull-request-status.py "${hash}" error \
		"QA checks crashed. Please rebase and check profile changes for syntax errors."
	sendmail "${CRONJOB_ADMIN_MAIL}" <<-EOF
		Subject: Pull request crash: ${iid}
		To: <${CRONJOB_ADMIN_MAIL}>
		Content-Type: text/plain; charset=utf8

		It seems that pull request check for ${iid} crashed [1].

		[1]:${PULL_REQUEST_REPO}/pull/${iid}
	EOF
	rm -f -- "${pull}"/current-pr
fi

for d in "${pull}"; do
	# populate with necessary files
	mkdir -p -- "${d}"/etc/portage
	if [[ ! -e ${d}/etc/portage/make.profile ]]; then
		rm -f -- "${d}"/etc/portage/make.profile
		cp -d -- /etc/portage/make.profile "${d}"/etc/portage
	fi
	if [[ ! -e ${d}/etc/portage/make.conf ]]; then
		cp -- /etc/portage/make.conf "${d}"/etc/portage
	fi

	cat > "${d}"/etc/portage/repos.conf <<-EOF || die
		[DEFAULT]
		main-repo = gentoo

		[gentoo]
		location = ${pull}/tmp
	EOF
done

cd -- "${mirror}"
git pull

# check if we have anything to process
mkdir -p -- "${pull}"
prid=$( "${SCRIPT_DIR}"/pull-request/scan-pull-requests.py )

if [[ -n ${prid} ]]; then
	echo "${prid}" > current-pr

	cd -- "${sync}"
	ref=refs/pull/${prid}
	git fetch -f origin "refs/pull/${prid}/head:${ref}"

	hash=$(git rev-parse "${ref}")

	cd -- "${pull}"
	rm -rf -- tmp gentoo-ci

	git clone -s --no-checkout "${mirror}" tmp
	cd -- tmp
	git fetch "${sync}" "${ref}:${ref}"
	# start on top of last common commit, like fast-forward would do
	git branch "pull-${prid}" "$(git merge-base "${ref}" master)"
	git checkout -q "pull-${prid}"
	# copy existing md5-cache (TODO: try to find previous merge commit)
	rsync -rlpt --delete "${mirror}"/metadata/{dtd,glsa,md5-cache,news,xml-schema} metadata

	# merge the PR on top of cache
	git tag pre-merge
	git merge --quiet -m "Merge PR ${prid}" "${ref}"

	# update cache
	CONFIG_DIR=${pull}/etc/portage
	time timeout -k 30s "${PMAINT_TIMEOUT}" pmaint --config "${CONFIG_DIR}" \
		regen --use-local-desc --pkg-desc-index -t 16 gentoo || :

	cd ..
	git clone -s "${gentooci}" gentoo-ci
	cd -- gentoo-ci
	git checkout -b "pull-${prid}"
	( cd -- "${pull}"/tmp &&
		time HOME=${pull}/gentoo-ci \
		timeout -k 30s "${CI_TIMEOUT}" pkgcheck --config "${CONFIG_DIR}" \
			scan --reporter XmlReporter ${PKGCHECK_PR_OPTIONS}
	) | xsltproc "${SCRIPT_DIR}"/sort-output.xsl - > output.xml
	# ^^ Sort XML for better Git delta compression
	ts=$(cd -- "${pull}"/tmp; git log --pretty='%ct' -1)
	"${PKGCHECK_RESULT_PARSER_GIT}"/pkgcheck2borked.py \
		-x "${PKGCHECK_RESULT_PARSER_GIT}"/excludes.json \
		-w -e -o borked.list *.xml

	git add -- *.xml
	git diff --cached --quiet --exit-code || git commit -a -m "PR ${prid} @ $(date -u --date="@${ts}" "+%Y-%m-%d %H:%M:%S UTC")"
	pr_hash=$(git rev-parse --short HEAD)
	git push -f origin "pull-${prid}"

	cd -- "${gentooci}"
	git push -f origin "pull-${prid}"
	curl "https://qa-reports-cdn-origin.gentoo.org/cgi-bin/trigger-pull.cgi?gentoo-ci" || :

	# if we have any breakages...
	if [[ -s ${pull}/gentoo-ci/borked.list ]]; then
		pkgs=()
		while read l; do
			[[ ${l} ]] && pkgs+=( "${l}" )
		done <"${pull}"/gentoo-ci/borked.list

		# go back to pre-merge state and see if they were there
		cd -- "${pull}"/tmp
		git checkout -q pre-merge

		if [[ ${#pkgs[@]} -le ${PULL_REQUEST_BORKED_LIMIT} ]]; then
			outfiles=()

			if [[ ${#pkgs[@]} -gt 0 ]]; then
				pkgcheck --config "${CONFIG_DIR}" \
					scan --reporter XmlReporter "${pkgs[@]}" \
					${PKGCHECK_PR_OPTIONS} \
					-s pkg,ver \
					> .pre-merge.xml
				outfiles+=( .pre-merge.xml )
			fi

			pkgcheck --config "${CONFIG_DIR}" \
				scan --reporter XmlReporter "*/*" \
				${PKGCHECK_PR_OPTIONS} \
				-s repo,cat \
				> .pre-merge-g.xml
			outfiles+=( .pre-merge-g.xml )

			"${PKGCHECK_RESULT_PARSER_GIT}"/pkgcheck2borked.py \
				-x "${PKGCHECK_RESULT_PARSER_GIT}"/excludes.json \
				-w -e -o .pre-merge.borked "${outfiles[@]}"
		else
			echo ETOOMANY > .pre-merge.borked
		fi
	fi

	"${SCRIPT_DIR}"/pull-request/report-pull-request.py "${prid}" "${pr_hash}" \
		"${pull}"/gentoo-ci/borked.list .pre-merge.borked "${hash}"

	rm -f -- current-pr

	rm -rf -- "${pull}"/tmp "${pull}"/gentoo-ci
fi
