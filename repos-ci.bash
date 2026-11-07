#!/bin/bash
# run repos & CI combined

ret=0

for cmd in "${SCRIPT_DIR}"/repos/repos.bash "${SCRIPT_DIR}"/gentoo-ci/gentoo-ci.bash ; do
	timeout 60m ${cmd}
	: $(( ret |= $? ))
done

exit ${ret}
