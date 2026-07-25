#!/bin/bash
# TODO: Comment that this file is run by..

source "${0%/*}/../repo-mirror-ci.conf"

set -e -x

# SANITY!
export TZ=UTC

pull=${HOME}
sync=${SYNC_DIR}/gentoo
mirror=${MIRROR_DIR}/gentoo
gentooci=${GENTOO_CI_GIT}

for d in "${pull}"; do
	# populate with necessary files
	mkdir -p -- "${d}"/etc/portage
	if [[ ! -e ${d}/etc/portage/make.profile ]]; then
		rm -f -- "${d}"/etc/portage/make.profile
		ln -sf -- /etc/portage/make.profile "${d}"/etc/portage
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

# Wrapper around setpriv(1) for landlock. We want to limit what a compromised
# pmaint regen process can do (as it sources untrusted ebuilds), including
# not being able to tamper with other repositories being processed.
create_pmaint_setpriv_wrapper() {
	cat <<-EOF > /var/lib/repo-mirror-ci/pmaint-wrapper
	#!/bin/bash
	set -x

	portage_dir=\$1
	repos_dir=\$2
	repo_dir=\$3
	shift
	shift
	shift

	setpriv_args=(
		--landlock-access fs

		--landlock-rule path-beneath:read-file:/dev/null
		--landlock-rule path-beneath:write-file:/dev/null

		# Try to let pmaint emit errors when run under cron
		--landlock-rule path-beneath:read-file:/dev/stdout
		--landlock-rule path-beneath:read-file:/dev/stderr
		--landlock-rule path-beneath:write-file:/dev/stdout
		--landlock-rule path-beneath:write-file:/dev/stderr
		--landlock-rule path-beneath:ioctl-dev:/dev/stdout
		--landlock-rule path-beneath:ioctl-dev:/dev/stderr
		--landlock-rule path-beneath:ioctl-dev:/dev/tty
		--landlock-rule path-beneath:read-file:/dev/pts
		--landlock-rule path-beneath:read-dir:/dev/pts
		--landlock-rule path-beneath:write-file:/dev/pts
		--landlock-rule path-beneath:ioctl-dev:/dev/pts

		--landlock-rule path-beneath:read-file:/dev/tty
		--landlock-rule path-beneath:write-file:/dev/tty

		--landlock-rule path-beneath:write-file:/tmp

		# sandbox.log
		--landlock-rule path-beneath:make-reg:/tmp
		--landlock-rule path-beneath:remove-file:/tmp

		--landlock-rule path-beneath:read-dir:/etc/sandbox.d
		--landlock-rule path-beneath:read-file:/etc/sandbox.d
		--landlock-rule path-beneath:read-file:/etc/sandbox.conf
		--landlock-rule path-beneath:read-file:/usr/share/sandbox/sandbox.bashrc

		# Needed for make.profile symlink
		--landlock-rule path-beneath:read-dir:/var/db/repos/gentoo
		--landlock-rule path-beneath:read-file:/var/db/repos/gentoo

		--landlock-rule path-beneath:read-dir:\${portage_dir}
		--landlock-rule path-beneath:read-file:\${portage_dir}

		# Any repository may need to read any other repository because
		# of repo masters.
		--landlock-rule path-beneath:read-dir:\${repos_dir}
		--landlock-rule path-beneath:read-file:\${repos_dir}

		# Only allow writing to the specific repo we're operating on.
		--landlock-rule path-beneath:write-file:\${repo_dir}/metadata
		--landlock-rule path-beneath:write-file:\${repo_dir}/profiles
		--landlock-rule path-beneath:make-dir:\${repo_dir}/metadata
		--landlock-rule path-beneath:make-reg:\${repo_dir}
		--landlock-rule path-beneath:remove-file:\${repo_dir}/metadata
		--landlock-rule path-beneath:remove-file:\${repo_dir}/profiles
	)

	# Needed for Python to be able to find libb2 for hashlib
	for file in /etc/ld.so.cache ; do
		setpriv_args+=(
			--landlock-rule path-beneath:read-file:\${file}
		)
	done
	# Needed to call pmaint or called by pmaint
	for file in /usr/bin/pmaint /usr/bin/python3.?? /usr/bin/python-exec2c /bin/bash \
			/usr/bin/sandbox /bin/stty /usr/bin/env \
			/usr/bin/readlink /usr/bin/sort ; do
		setpriv_args+=(
			--landlock-rule path-beneath:read-file:\${file}
			--landlock-rule path-beneath:execute:\${file}
		)
	done
	for dir in /usr/lib/python-exec /usr/lib64/python-exec ; do
		setpriv_args+=(
			--landlock-rule path-beneath:read-dir:\${dir}
			--landlock-rule path-beneath:read-file:\${dir}
			--landlock-rule path-beneath:execute:\${dir}
		)
	done
	# Not just for Python itself but also the loader..
	for dir in /usr/lib64 /lib64 /usr/lib/pkgcore ; do
		setpriv_args+=(
			--landlock-rule path-beneath:read-dir:\${dir}
			--landlock-rule path-beneath:read-file:\${dir}
			--landlock-rule path-beneath:execute:\${dir}
		)
	done
	# site-packages
	for dir in /usr/lib/python3.?? /etc/python-exec ; do
		setpriv_args+=(
			--landlock-rule path-beneath:read-dir:\${dir}
			--landlock-rule path-beneath:read-file:\${dir}
		)
	done
	# portage+pkgcore config
	for dir in /usr/share/portage /usr/share/pkgcore ; do
		setpriv_args+=(
			--landlock-rule path-beneath:read-dir:\${dir}
			--landlock-rule path-beneath:read-file:\${dir}
		)
	done
	EOF

	chmod +x /var/lib/repo-mirror-ci/pmaint-wrapper
}

create_pmaint_setpriv_wrapper

pr=${1}
forge="${pr%/*}"
prid="${pr#*/}"
ref=refs/pull/${pr}

cd
rm -rf -- tmp gentoo-ci

git clone -s --no-checkout "${mirror}" tmp
cd -- tmp
git fetch "${sync}" "${ref}:${ref}"
# start on top of last common commit, like fast-forward would do
git branch "pull-${forge}-${prid}" "$(git merge-base "${ref}" master)"
git checkout -q "pull-${forge}-${prid}"
# copy existing md5-cache (TODO: try to find previous merge commit)
rsync -rlpt --delete "${mirror}"/metadata/{dtd,glsa,md5-cache,news,xml-schema} metadata

# merge the PR on top of cache
git tag pre-merge
git merge --quiet -m "Merge PR ${pr}" "${ref}"

# update cache
CONFIG_DIR=${pull}/etc/portage

if ! time timeout -k 30s "${PMAINT_TIMEOUT}" /var/lib/repo-mirror-ci/pmaint-wrapper \
	"${CONFIG_ROOT}" "${REPOS_DIR}" "${REPOS_DIR}"/gentoo \
	pmaint --config "${CONFIG_DIR}" regen --use-local-desc --pkg-desc-index -t "$(nproc)" gentoo ; then
	ret=$?
	echo ETOOMANY > .pre-merge.borked
	exit ${ret}
fi

cd ..
git clone -s "${gentooci}" gentoo-ci
cd -- gentoo-ci
git checkout -b "pull-${forge}-${prid}"

pushd -- "${pull}"/tmp >/dev/null
HOME=${pull}/gentoo-ci time timeout -k 30s "${CI_TIMEOUT}" \
	pkgcheck --config "${CONFIG_DIR}" scan \
	--reporter XmlReporter ${PKGCHECK_PR_OPTIONS} > output.xml.tmp
popd >/dev/null
# Sort XML for better Git delta compression
cat "${pull}"/tmp/output.xml.tmp | xsltproc "${SCRIPT_DIR}"/sort-output.xsl - > output.xml
rm "${pull}"/tmp/output.xml.tmp

ts=$(cd -- "${pull}"/tmp; git log --pretty='%ct' -1)
"${PKGCHECK_RESULT_PARSER_GIT}"/pkgcheck2borked.py \
	-x "${PKGCHECK_RESULT_PARSER_GIT}"/excludes.json \
	-w -e -o borked.list *.xml

git add -- *.xml
git diff --cached --quiet --exit-code || git commit -a -m "PR ${pr} @ $(date -u --date="@${ts}" "+%Y-%m-%d %H:%M:%S UTC")"

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
