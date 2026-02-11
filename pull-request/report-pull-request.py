#!/usr/bin/env python

import datetime
import os
import os.path
import sys

import github
from codebergapi import CodebergAPI


def report_codeberg_pr(
    prid, prhash, borked, pre_borked, too_many_borked, report_uri_prefix, commit_hash
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
        for co in cb.get_reviews(prid):
            if co["user"]["login"] == CODEBERG_USERNAME:
                body = co["body"]
                if "All QA issues have been fixed" in body:
                    had_broken = False
                elif "has found no issues" in body:
                    had_broken = False
                elif "No issues found" in body:
                    had_broken = False
                elif "New issues" in body:
                    had_broken = True
                elif "Issues already there" in body:
                    had_broken = True
                elif "Issues inherited from Gentoo" in body:
                    had_broken = True
                elif "There are existing issues already" in body:
                    had_broken = True
                elif "too many broken packages" in body:
                    had_broken = True
                else:
                    # skip comments that don't look like CI results
                    continue
                old_comments.append(co)

        for co in old_comments:
            cb.delete_review(prid, co["id"])

        report_url = report_uri_prefix + "/" + prhash + "/output.html"
        body = f"""## Pull request CI report

*Report generated at*: {datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M UTC")}
*Newest commit scanned*: {commit_hash}
*Status*: {":x: **broken**" if borked else ":white_check_mark: good"}
"""

        if borked or pre_borked:
            if borked:
                if too_many_borked:
                    body += "\nThere are too many broken packages to determine whether the breakages were added by the pull request. If in doubt, please rebase.\n\nIssues:"
                else:
                    body += "\nNew issues caused by PR:\n"
                for url in borked:
                    body += url
            if pre_borked:
                body += f"\nThere are existing issues already. Please look into the report to make sure none of them affect the packages in question:\n{report_url}\n"
        elif had_broken:
            body += "\nAll QA issues have been fixed!\n"
        else:
            body += "\nNo issues found\n"

        cb.create_review(prid, body)

        if borked:
            cb.commit_set_status(
                commit_hash,
                "failure",
                description="PR introduced new issues",
                target_url=report_url,
                context="gentoo-ci",
            )
        elif pre_borked:
            cb.commit_set_status(
                commit_hash,
                "success",
                description="No new issues found",
                target_url=report_url,
                context="gentoo-ci",
            )
        else:
            cb.commit_set_status(
                commit_hash,
                "success",
                description="All pkgcheck QA checks passed",
                target_url=report_url,
                context="gentoo-ci",
            )


def report_github_pr(
    prid, prhash, borked, pre_borked, too_many_borked, report_uri_prefix, commit_hash
):
    GITHUB_USERNAME = os.environ["GITHUB_USERNAME"]
    GITHUB_TOKEN_FILE = os.environ["GITHUB_TOKEN_FILE"]
    GITHUB_REPO = os.environ["GITHUB_REPO"]

    with open(GITHUB_TOKEN_FILE) as f:
        token = f.read().strip()

    g = github.Github(GITHUB_USERNAME, token, per_page=50)
    r = g.get_repo(GITHUB_REPO)
    pr = r.get_pull(int(prid))
    c = r.get_commit(commit_hash)

    # delete old results
    had_broken = False
    old_comments = []
    # note: technically we could have multiple leftover comments
    for co in pr.get_issue_comments():
        if co.user.login == GITHUB_USERNAME:
            if "All QA issues have been fixed" in co.body:
                had_broken = False
            elif "has found no issues" in co.body:
                had_broken = False
            elif "No issues found" in co.body:
                had_broken = False
            elif "New issues" in co.body:
                had_broken = True
            elif "Issues already there" in co.body:
                had_broken = True
            elif "Issues inherited from Gentoo" in co.body:
                had_broken = True
            elif "There are existing issues already" in co.body:
                had_broken = True
            elif "too many broken packages" in co.body:
                had_broken = True
            else:
                # skip comments that don't look like CI results
                continue
            old_comments.append(co)
    for co in old_comments:
        co.delete()

    report_url = report_uri_prefix + "/" + prhash + "/output.html"
    body = """## Pull request CI report

*Report generated at*: %s
*Newest commit scanned*: %s
*Status*: %s
""" % (
        datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M UTC"),
        commit_hash,
        ":x: **broken**" if borked else ":white_check_mark: good",
    )

    if borked or pre_borked:
        if borked:
            if too_many_borked:
                body += "\nThere are too many broken packages to determine whether the breakages were added by the pull request. If in doubt, please rebase.\n\nIssues:"
            else:
                body += "\nNew issues caused by PR:\n"
            for url in borked:
                body += url
        if pre_borked:
            body += (
                "\nThere are existing issues already. Please look into the report to make sure none of them affect the packages in question:\n%s\n"
                % report_url
            )
    elif had_broken:
        body += "\nAll QA issues have been fixed!\n"
    else:
        body += "\nNo issues found\n"

    pr.create_issue_comment(body)

    if borked:
        c.create_status(
            "failure",
            description="PR introduced new issues",
            target_url=report_url,
            context="gentoo-ci",
        )
    elif pre_borked:
        c.create_status(
            "success",
            description="No new issues found",
            target_url=report_url,
            context="gentoo-ci",
        )
    else:
        c.create_status(
            "success",
            description="All pkgcheck QA checks passed",
            target_url=report_url,
            context="gentoo-ci",
        )


def main(forge, prid, prhash, borked_path, pre_borked_path, commit_hash):
    REPORT_URI_PREFIX = os.environ["GENTOO_CI_URI_PREFIX"]

    borked = []
    with open(borked_path) as f:
        for l in f:
            borked.append(REPORT_URI_PREFIX + "/" + prhash + "/output.html#" + l)

    pre_borked = []
    too_many_borked = False
    if borked:
        with open(pre_borked_path) as f:
            for l in f:
                if l.strip() == "ETOOMANY":
                    too_many_borked = True
                    break

                lf = REPORT_URI_PREFIX + "/" + prhash + "/output.html#" + l
                if lf in borked:
                    pre_borked.append(lf)
                    borked.remove(lf)

    if forge == "github":
        report_github_pr(
            prid,
            prhash,
            borked,
            pre_borked,
            too_many_borked,
            REPORT_URI_PREFIX,
            commit_hash,
        )
    elif forge == "codeberg":
        report_codeberg_pr(
            prid,
            prhash,
            borked,
            pre_borked,
            too_many_borked,
            REPORT_URI_PREFIX,
            commit_hash,
        )


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
