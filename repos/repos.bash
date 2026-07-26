#!/bin/bash

set -e -x
ulimit -t 800

# SANITY!
export TZ=UTC

date=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

# Create base part of setpriv wrapper which gets appended later.
create_base_setpriv_wrapper() {
	local filename=$1

	cat <<-EOF > /var/lib/repo-mirror-ci/${filename}
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

	chmod +x /var/lib/repo-mirror-ci/${filename}
}

# Wrapper around setpriv(1) for landlock. We want to limit what a compromised
# pmaint sync process can do, including not being able to tamper with other
# repositories being processed.
create_pmaint_sync_setpriv_wrapper() {
	create_base_setpriv_wrapper pmaint-sync-wrapper

	cat <<-EOF >> /var/lib/repo-mirror-ci/pmaint-sync-wrapper
	# Sync methods
	for bin in /usr/bin/git /usr/libexec/git-core ; do
		setpriv_args+=(
			--landlock-rule path-beneath:read-file:\${bin}
			--landlock-rule path-beneath:execute:\${bin}
		)
	done

	setpriv_args+=(
		# Fetching
		--landlock-rule path-beneath:read-file:/etc/resolv.conf
		--landlock-rule path-beneath:read-file:/etc/nsswitch.conf
		--landlock-rule path-beneath:read-file:/etc/ssl/certs/ca-certificates.crt

		# Only allow writing to the specific repo we're operating on.
		--landlock-rule path-beneath:read-dir:\${repo_dir}
		--landlock-rule path-beneath:read-file:\${repo_dir}
		--landlock-rule path-beneath:write-file:\${repo_dir}
		--landlock-rule path-beneath:make-dir:\${repo_dir}
		--landlock-rule path-beneath:make-reg:\${repo_dir}
		--landlock-rule path-beneath:remove-dir:\${repo_dir}
		--landlock-rule path-beneath:remove-file:\${repo_dir}
		# git uses truncate for some files in .git
		--landlock-rule path-beneath:truncate:\${repo_dir}
	)

	exec setpriv "\${setpriv_args[@]}" -- "\$@"
	EOF
}

# Wrapper around setpriv(1) for landlock. We want to limit what a compromised
# pmaint regen process can do (as it sources untrusted ebuilds), including
# not being able to tamper with other repositories being processed.
create_pmaint_setpriv_wrapper() {
	create_base_setpriv_wrapper pmaint-wrapper
	cat <<-EOF >> /var/lib/repo-mirror-ci/pmaint-wrapper
	exec setpriv "\${setpriv_args[@]}" -- "\$@"
	EOF
}

mkdir -p -- "${CONFIG_ROOT}" "${CONFIG_ROOT_MIRROR}" "${CONFIG_ROOT_SYNC}" \
	"${SYNC_DIR}" "${MIRROR_DIR}" "${REPOS_DIR}"
for d in "${CONFIG_ROOT}" "${CONFIG_ROOT_MIRROR}" "${CONFIG_ROOT_SYNC}"
do
	# populate with necessary files
	mkdir -p -- "${d}"/etc/portage
	if [[ ! -e ${d}/etc/portage/make.profile ]]; then
		rm -f -- "${d}"/etc/portage/make.profile
		ln -s -- "$(readlink -f /etc/portage/make.profile)" "${d}"/etc/portage/make.profile
	fi
	if [[ ! -e ${d}/etc/portage/make.conf ]]; then
		cp -- /etc/portage/make.conf "${d}"/etc/portage
	fi
	if [[ ! -e ${d}/etc/portage/repos.conf ]]; then
		case ${d} in
			"${CONFIG_ROOT_SYNC}")
				repo_root=${SYNC_DIR}
				;;
			"${CONFIG_ROOT}")
				repo_root=${REPOS_DIR}
				;;
			"${CONFIG_ROOT_MIRROR}")
				repo_root=${MIRROR_DIR}
				;;
			*)
				exit 1
		esac

		for r in ${REPOS}; do
			name=${r%%:*}
			url=${r#*:}
			cat >> "${d}/etc/portage/repos.conf" <<-EOF
				[${name}]
				location = ${repo_root}/${name}
				clone-depth = 0
				sync-type = git
				sync-depth = 0
				sync-uri = ${url}
			EOF
		done
	fi
done

create_pmaint_sync_setpriv_wrapper
create_pmaint_setpriv_wrapper

# sync all repos
for r in ${REPOS}; do
	name=${r%%:*}

	/var/lib/repo-mirror-ci/pmaint-sync-wrapper \
		"${CONFIG_ROOT_SYNC}/etc/portage" \
		"${SYNC_DIR}" \
		"${SYNC_DIR}/${name}" \
		pmaint --config "${CONFIG_ROOT_SYNC}/etc/portage" sync "${name}"
done

# check signed repos
for r in ${SIGNED_REPOS}; do
	[[ $(
		cd "${SYNC_DIR}/${r}" && git show -q --pretty="format:%G?" HEAD
	) == [GU] ]]
done

# rsync repos to main dir
rsync --recursive --links --times --delete \
	'--exclude=.*/' \
	'--exclude=*/metadata/md5-cache' \
	'--exclude=*/profiles/use.local.desc' \
	'--exclude=*/metadata/pkg_desc_index' \
	'--exclude=*/metadata/timestamp.chk' \
	"${SYNC_DIR}/." "${REPOS_DIR}"

# The setfacl commands may fail if ${WORKER_USER} already owns them but
# that's fine for us.
#
# Make sure repormirorci itself always has permissions even if repomirrorci-worker
# is the owner.
setfacl -d -R -m u:${USER}:rwx "${REPOS_DIR}" ||:
# The worker (in repomirrorci group) has to be able to write new cache
# entries.
setfacl -d -R -m g:${USER}:rwx "${REPOS_DIR}" ||:

# prepare mirrors
for r in ${REPOS}; do
	name=${r%%:*}

	# regen caches
	sudo -u "${WORKER_USER}" \
		bwrap --bind / / --dev /dev --proc /proc --unshare-all \
		--uid $(id -u "${WORKER_USER}") --gid $(id -g "${WORKER_USER}") \
		/var/lib/repo-mirror-ci/pmaint-wrapper \
		"${CONFIG_ROOT}/etc/portage" "${REPOS_DIR}" "${REPOS_DIR}/${name}" \
		pmaint --config "${CONFIG_ROOT}/etc/portage" regen \
		--use-local-desc --pkg-desc-index -t "$(nproc)" "${name}"

	if [[ ! -e ${MIRROR_DIR}/${name} ]]; then
		git clone "git@github.com:gentoo-mirror/${name}" \
			"${MIRROR_DIR}/${name}"
	fi

	"${SCRIPT_DIR}"/repos/smart-merge.bash "${SYNC_DIR}/${name}" \
		"${MIRROR_DIR}/${name}" master

	# Calls bash hooks that may need network access
	# e.g. gentoo needs glsa, news
	"${SCRIPT_DIR}/repos/repo-postmerge/${name}" "${MIRROR_DIR}/${name}"

	# Verification step to make sure smart-merge didn't go wrong
	# TODO: Is this really needed anymore?
	rsync --recursive --links --times --delete \
		'--exclude=.*/' \
		'--exclude=metadata/timestamp.chk' \
		'--exclude=metadata/dtd' \
		'--exclude=metadata/glsa' \
		'--exclude=metadata/news' \
		'--exclude=metadata/projects.xml' \
		'--exclude=metadata/xml-schema' \
		"${REPOS_DIR}/${name}/." "${MIRROR_DIR}/${name}/"

	(
		cd "${MIRROR_DIR}/${name}"
		git add -A -f
		if ! git diff --cached --quiet --exit-code; then
			LANG=C date -u "+%a, %d %b %Y %H:%M:%S +0000" > metadata/timestamp.chk
			git add -f metadata/timestamp.chk
			git commit --quiet -m "$(date -u '+%F %T UTC')"
		fi
		out=$(git rev-list origin/master..master)
		ret=$?
		if [[ -n "${out}" || "${ret}" -ne 0 ]]; then
			git fetch --all
			git push
		fi
	)
done
