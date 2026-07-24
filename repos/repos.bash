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
rsync --recursive --links --perms --times --delete \
	'--exclude=.*/' \
	'--exclude=*/metadata/md5-cache' \
	'--exclude=*/profiles/use.local.desc' \
	'--exclude=*/metadata/pkg_desc_index' \
	'--exclude=*/metadata/timestamp.chk' \
	"${SYNC_DIR}/." "${REPOS_DIR}"

# regen caches
# (ignore failures, if it's ::gentoo, pkgcheck should detect it)
pmaint --config "${CONFIG_ROOT}/etc/portage" regen \
	--use-local-desc --pkg-desc-index -t "$(nproc)" || :

# prepare mirrors
for r in ${REPOS}; do
	name=${r%%:*}

	if [[ ! -e ${MIRROR_DIR}/${name} ]]; then
		git clone "git@github.com:gentoo-mirror/${name}" \
			"${MIRROR_DIR}/${name}"
	fi

	"${SCRIPT_DIR}"/repos/smart-merge.bash "${SYNC_DIR}/${name}" \
		"${MIRROR_DIR}/${name}" master

	# Calls bash hooks that may need network access
	# e.g. gentoo needs glsa, news
	"${SCRIPT_DIR}/repos/repo-postmerge/${name}" "${MIRROR_DIR}/${name}"

	rsync --recursive --links --perms --times --delete \
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
