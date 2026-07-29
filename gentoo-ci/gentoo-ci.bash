#!/bin/bash

set -e -x

# SANITY!
export TZ=UTC

# Wrapper around setpriv(1) for landlock. We want to limit what a compromised
# pkgcheck process can do (as it sources untrusted ebuilds)
create_pkgcheck_setpriv_wrapper() {
	cat <<-EOF > ${DATA_DIR}/pkgcheck-wrapper
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

		# Try to let pkgcheck emit errors when run under cron
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

		# Python's multiprocessing module creates locks here
		--landlock-rule path-beneath:read-dir:/dev/shm
		--landlock-rule path-beneath:read-file:/dev/shm
		--landlock-rule path-beneath:write-file:/dev/shm
		--landlock-rule path-beneath:make-reg:/dev/shm
		--landlock-rule path-beneath:remove-file:/dev/shm

		--landlock-rule path-beneath:read-dir:${WORKER_DIR}/.cache/pkgcheck
		--landlock-rule path-beneath:read-file:${WORKER_DIR}/.cache/pkgcheck
		--landlock-rule path-beneath:write-file:${WORKER_DIR}/.cache/pkgcheck
		--landlock-rule path-beneath:make-reg:${WORKER_DIR}/.cache/pkgcheck
		--landlock-rule path-beneath:remove-dir:${WORKER_DIR}/.cache/pkgcheck
		--landlock-rule path-beneath:remove-file:${WORKER_DIR}/.cache/pkgcheck
		--landlock-rule path-beneath:truncate:${WORKER_DIR}/.cache/pkgcheck
		--landlock-rule path-beneath:make-dir:${WORKER_DIR}/.cache/pkgcheck

		# Used to compress cache
		--landlock-rule path-beneath:execute:/usr/bin/zstd
		--landlock-rule path-beneath:read-file:/usr/bin/zstd

		# PerlCheck
		--landlock-rule path-beneath:execute:/usr/bin/perl
		--landlock-rule path-beneath:read-file:/usr/bin/perl
		--landlock-rule path-beneath:read-file:/usr/share/pkgcheck/perl-version.pl
		--landlock-rule path-beneath:read-dir:/usr/lib64/perl5
		--landlock-rule path-beneath:read-file:/usr/lib64/perl5
	)

	# pkgcheck queries git for caching purposes
	for bin in /usr/bin/git /usr/libexec/git-core ; do
		setpriv_args+=(
			--landlock-rule path-beneath:read-file:\${bin}
			--landlock-rule path-beneath:execute:\${bin}
		)
	done

	# Needed for Python to be able to find libb2 for hashlib
	for file in /etc/ld.so.cache ; do
		setpriv_args+=(
			--landlock-rule path-beneath:read-file:\${file}
		)
	done
	# Needed to call pkgcheck or called by pkgcheck
	for file in /usr/bin/pkgcheck /usr/bin/python3.?? /usr/bin/python-exec2c /bin/bash \
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
	exec setpriv "\${setpriv_args[@]}" -- "\$@"
	EOF

	chmod +x ${DATA_DIR}/pkgcheck-wrapper
}

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

	create_pkgcheck_setpriv_wrapper

	pushd -- "${MIRROR_DIR}"/gentoo >/dev/null
	sudo -u "${WORKER_USER}" \
		bwrap --bind / / --dev /dev --proc /proc --unshare-all \
		--uid $(id -u "${WORKER_USER}") --gid $(id -g "${WORKER_USER}") \
		time timeout -k 30s "${CI_TIMEOUT}" \
		${DATA_DIR}/pkgcheck-wrapper \
		"${CONFIG_DIR}" \
		"${MIRROR_DIR}" \
		"${MIRROR_DIR}/gentoo" \
		pkgcheck --config "${CONFIG_DIR}" scan \
		--reporter XmlReporter ${PKGCHECK_OPTIONS} > output.xml.tmp
	popd >/dev/null
	# Sort XML for better Git delta compression
	cat "${MIRROR_DIR}"/gentoo/output.xml.tmp | xsltproc "${SCRIPT_DIR}"/sort-output.xsl - > output.xml
	rm "${MIRROR_DIR}"/gentoo/output.xml.tmp

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
