#!/bin/bash

set -e -x
ulimit -t 800

# SANITY!
export TZ=UTC

date=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

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

# sync all repos
pmaint --config "${CONFIG_ROOT_SYNC}/etc/portage" sync

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

#
# wrapper around setpriv(1) for landlock
#
cat <<-EOF > /tmp/pmaint-wrapper
#!/bin/bash
set -x

portage_dir=\$1
repo_dir=\$2
shift
shift

setpriv_args=(
	--landlock-access fs

	--landlock-rule path-beneath:read-dir:/
	--landlock-rule path-beneath:read-file:/

	--landlock-rule path-beneath:write-file:/dev/null

	--landlock-rule path-beneath:read-dir:/etc/sandbox.d
	--landlock-rule path-beneath:read-dir:/usr/lib/python-exec

	--landlock-rule path-beneath:read-dir:\${portage_dir}
	--landlock-rule path-beneath:read-file:\${portage_dir}

	--landlock-rule path-beneath:read-dir:\${repo_dir}
	--landlock-rule path-beneath:read-file:\${repo_dir}

	# Only allow writing to the specific repo we're operating on
	--landlock-rule path-beneath:write-file:\${repo_dir}/metadata
	--landlock-rule path-beneath:write-file:\${repo_dir}/profiles
	--landlock-rule path-beneath:make-dir:\${repo_dir}/metadata
	--landlock-rule path-beneath:make-reg:\${repo_dir}
	--landlock-rule path-beneath:remove-file:\${repo_dir}/metadata
	--landlock-rule path-beneath:remove-file:\${repo_dir}/profiles

	--landlock-rule path-beneath:execute:/
	--landlock-rule path-beneath:write-file:/tmp
)

for dir in /usr/lib/python3.?? ; do
	setpriv_args+=( --landlock-rule path-beneath:read-dir:\${dir} )
done

exec setpriv "\${setpriv_args[@]}" -- "\$@"
EOF
chmod +x /tmp/pmaint-wrapper

# prepare mirrors
for r in ${REPOS}; do
	name=${r%%:*}

	# regen caches
	# TODO: We may need to allow read for all repo dirs because of
	# repository masters?
	sudo -u "${WORKER_USER}" \
		bwrap --bind / / --dev /dev --proc /proc --unshare-all \
		--uid $(id -u "${WORKER_USER}") --gid $(id -g "${WORKER_USER}") \
		/tmp/pmaint-wrapper "${CONFIG_ROOT}/etc/portage" "${REPOS_DIR}/${name}" \
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
