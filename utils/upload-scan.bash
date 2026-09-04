#!/bin/bash
# Upload a pkgcheck XML report to gentoo-ci-http.
#
# The report is identified by the gentoo-ci git commit that carries it, so the
# same sha addresses it under both /output (git-backed) and /output2 while the
# two run side by side.
#
# Usage: upload-scan.bash <repo> <commit> <parent> <xml> [--branch]
#
#   repo    report set, matching the URL: /output2/<repo>/...
#   commit  scan id, normally the gentoo-ci commit sha
#   parent  scan this one was produced against; may be empty
#   xml     the report file
#   --branch  a PR scan: stored as a delta and never snapshotted
#
# Uploading is best-effort at the call site: a report already in git is not lost
# if this fails, so callers append `|| :`.

set -e

if [[ ${#} -lt 4 ]]; then
	echo "usage: ${0##*/} <repo> <commit> <parent> <xml> [--branch]" >&2
	exit 1
fi

repo=${1}
commit=${2}
parent=${3}
xml=${4}
branch=

if [[ ${5} == --branch ]]; then
	branch=1
fi

if [[ ! ${QA_REPORTS_UPLOAD_URL} ]]; then
	echo "${0##*/}: QA_REPORTS_UPLOAD_URL is unset, skipping upload" >&2
	exit 0
fi
if [[ ! -r ${QA_REPORTS_TOKEN_FILE} ]]; then
	echo "${0##*/}: no API token at ${QA_REPORTS_TOKEN_FILE}, skipping upload" >&2
	exit 0
fi
if [[ ! -s ${xml} ]]; then
	echo "${0##*/}: ${xml} is missing or empty, skipping upload" >&2
	exit 0
fi

# Candidate parents are tried in order and the first one the server already
# holds wins, so it does not matter that some of these may be absent.
query="commit=${commit}"
[[ ${branch} ]] && query+="&branch=1"
[[ ${parent} ]] && query+="&from=${parent}"

# No --fail: the status is inspected below, and letting curl fail the transfer
# would print its own error for a 409, which is a success here. A network-level
# failure leaves the status empty and is caught by the catch-all.
out=$(mktemp)
trap 'rm -f "${out}"' EXIT

status=$(
	curl --silent \
		--max-time 300 \
		--header "Authorization: Bearer $(< "${QA_REPORTS_TOKEN_FILE}")" \
		--header 'Content-Type: application/xml' \
		--data-binary "@${xml}" \
		--write-out '%{http_code}' \
		--output "${out}" \
		"${QA_REPORTS_UPLOAD_URL}/${repo}/${commit}/output.xml?${query}"
) || true

body=$(< "${out}")

case ${status} in
	201) echo "uploaded ${commit}: ${body}";;
	409) echo "${commit} already stored";;
	*)   echo "${0##*/}: upload of ${commit} failed (HTTP ${status:-none}): ${body}" >&2
	     exit 1;;
esac
