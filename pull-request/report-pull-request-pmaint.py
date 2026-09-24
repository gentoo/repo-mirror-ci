#!/usr/bin/env python
"""
Copy of report-pull-request.py just for reporting `pmaint regen` failures
from a given log to PRs.
"""

import datetime
import os
import os.path
import sys

import github
from codebergapi import CodebergAPI


HAD_BROKEN_SUBS = (
    "New issues",
    "Issues already there",
    "Issues inherited from Gentoo",
    "There are existing issues already",
    "too many broken packages",
)


def report_codeberg_pr(
    prid, prhash, pmaint_log
):
    CODEBERG_USERNAME = os.environ["CODEBERG_USERNAME"]
    CODEBERG_TOKEN_FILE = os.environ["CODEBERG_TOKEN_FILE"]
    (owner, repo) = os.environ["CODEBERG_REPO"].split("/")

    with open(CODEBERG_TOKEN_FILE) as f:
        token = f.read().strip()

    with CodebergAPI(owner, repo, token) as cb:
        # delete old results
        had_broken = False
        old_comments = []
        # note: technically we could have multiple leftover comments
        for co in cb.get_comments(prid):
            if co["user"]["login"] == CODEBERG_USERNAME:
                # skip comments that don't look like CI results
                if not co["body"].startswith("## Pull request CI report"):
                    continue
                old_comments.append(co["id"])
                had_broken = had_broken or any(
                    sub in co["body"] for sub in HAD_BROKEN_SUBS
                )

        for co_id in old_comments:
            cb.delete_comment(co_id)

        body = f"""## Pull request CI report

*Report generated at*: {datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M UTC")}
*Newest commit scanned*: {prhash}
*Status*: :x: **broken** (`pmaint regen` failed)
"""

        body += "\nNew issues found. Failed `pmaint regen` output follows:\n"
        body += "```\n"
        with open(pmaint_log, "r") as f:
            body += '\n'.join(f.readlines())
        body += "```\n"

        cb.create_comment(prid, body)
        cb.commit_set_status(
            prhash,
            "failure",
            description="PR introduced new issues",
            context="gentoo-ci",
        )

def report_github_pr(
    prid, prhash, pmaint_log
):
    GITHUB_USERNAME = os.environ["GITHUB_USERNAME"]
    GITHUB_TOKEN_FILE = os.environ["GITHUB_TOKEN_FILE"]
    GITHUB_REPO = os.environ["GITHUB_REPO"]

    with open(GITHUB_TOKEN_FILE) as f:
        token = f.read().strip()

    g = github.Github(GITHUB_USERNAME, token, per_page=50)
    r = g.get_repo(GITHUB_REPO)
    pr = r.get_pull(int(prid))
    c = r.get_commit(prhash)

    # delete old results
    had_broken = False
    old_comments = []
    # note: technically we could have multiple leftover comments
    for co in pr.get_issue_comments():
        if co.user.login == GITHUB_USERNAME:
            # skip comments that don't look like CI results
            if not co.body.startswith("## Pull request CI report"):
                continue
            old_comments.append(co)
            had_broken = had_broken or any(sub in co.body for sub in HAD_BROKEN_SUBS)
    for co in old_comments:
        co.delete()

    body = """## Pull request CI report

*Report generated at*: %s
*Newest commit scanned*: %s
*Status*: %s
""" % (
        datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M UTC"),
        prhash,
        ":x: **broken**",
    )

    body += "\nNew issues found. Failed `pmaint regen` output follows:\n"
    body += "```\n"
    with open(pmaint_log, "r") as f:
        body += '\n'.join(f.readlines())
    body += "```\n"

    pr.create_issue_comment(body)
    c.create_status(
        "failure",
        description="PR introduced new issues",
        context="gentoo-ci",
    )


def main(forge, prid, prhash, pmaint_log):
    if forge == "github":
        report_github_pr(
            prid,
            prhash,
            pmaint_log,
        )
    elif forge == "codeberg":
        report_codeberg_pr(
            prid,
            prhash,
            pmaint_log,
        )


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
