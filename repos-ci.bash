#!/bin/bash
# run repos & CI combined
. /lib/gentoo/functions.sh

ret=0
failed_cmds=()

for cmd in "${SCRIPT_DIR}"/repos/repos.bash "${SCRIPT_DIR}"/gentoo-ci/gentoo-ci.bash ; do
	timeout 60m ${cmd}
	tmp=$?
	: $(( ret |= ${tmp} ))

	if (( ${tmp} != 0 )) ; then
		failed_cmds+=( "${cmd}" )
	fi
done

# Summarise failed commands at the end
for cmd in "${failed_cmds[@]}" ; do
	eerror "Command failed: ${cmd}"
done

exit ${ret}
