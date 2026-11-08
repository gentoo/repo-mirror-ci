#!/bin/bash
# Run repos & CI combined

. /lib/gentoo/functions.sh

ret=0
failed_cmds=()

# repos.bash may fail but still have pulled gentoo, so keep going and report
# failure at the end instead.
for cmd in "${SCRIPT_DIR}"/repos/repos.bash "${SCRIPT_DIR}"/gentoo-ci/gentoo-ci.bash ; do
	ebegin "Running ${cmd}"

	timeout 60m ${cmd}
	tmp=$?
	: $(( ret |= ${tmp} ))

	if (( ${tmp} != 0 )) ; then
		failed_cmds+=( "${cmd}" )
	fi

	eend ${tmp}
done

# Summarise failed commands at the end
for cmd in "${failed_cmds[@]}" ; do
	eerror "Command failed: ${cmd}"
done

exit ${ret}
