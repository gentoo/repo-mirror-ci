#!/usr/bin/env python

import datetime
import os
import os.path
import sys

from codebergapi import CodebergAPI


def main(prid, prhash, borked_path, pre_borked_path, commit_hash):
    CODEBERG_USERNAME = os.environ['CODEBERG_USERNAME']
    CODEBERG_TOKEN_FILE = os.environ['CODEBERG_TOKEN_FILE']
    (owner, repo) = os.environ['CODEBERG_REPO'].split('/')

    REPORT_URI_PREFIX = os.environ['GENTOO_CI_URI_PREFIX']

    borked = []
    with open(borked_path) as f:
        for l in f:
            borked.append(REPORT_URI_PREFIX + '/' + prhash + '/output.html#' + l)

    pre_borked = []
    too_many_borked = False
    prid = int(prid)
    if borked:
        with open(pre_borked_path) as f:
            for l in f:
                if l.strip() == 'ETOOMANY':
                    too_many_borked = True
                    break

                lf = REPORT_URI_PREFIX + '/' + prhash + '/output.html#' + l
                if lf in borked:
                    pre_borked.append(lf)
                    borked.remove(lf)

    with open(CODEBERG_TOKEN_FILE) as f:
        token = f.read().strip()

    cb = CodebergAPI(owner, repo, token)

    # delete old results
    had_broken = False
    old_comments = []
    # note: technically we could have multiple leftover comments
    for co in cb.get_reviews(prid):
        if co['user']['login'] == CODEBERG_USERNAME:
            body = co['body']
            if 'All QA issues have been fixed' in body:
                had_broken = False
            elif 'has found no issues' in body:
                had_broken = False
            elif 'No issues found' in body:
                had_broken = False
            elif 'New issues' in body:
                had_broken = True
            elif 'Issues already there' in body:
                had_broken = True
            elif 'Issues inherited from Gentoo' in body:
                had_broken = True
            else:
                # skip comments that don't look like CI results
                continue
            old_comments.append(co)

    for co in old_comments:
        cb.delete_review(prid, co['id'])

    report_url = REPORT_URI_PREFIX + '/' + prhash + '/output.html'
    body = f'''## Pull request CI report

*Report generated at*: {datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%d %H:%M UTC')}
*Newest commit scanned*: {commit_hash}
*Status*: {':x: **broken**' if borked else ':white_check_mark: good'}
'''

    if borked or pre_borked:
        if borked:
            if too_many_borked:
                body += '\nThere are too many broken packages to determine whether the breakages were added by the pull request. If in doubt, please rebase.\n\nIssues:'
            else:
                body += '\nNew issues caused by PR:\n'
            for url in borked:
                body += url
        if pre_borked:
            body += f'\nThere are existing issues already. Please look into the report to make sure none of them affect the packages in question:\n{report_url}s\n'
    elif had_broken:
        body += '\nAll QA issues have been fixed!\n'
    else:
        body += '\nNo issues found\n'

    cb.create_review(prid, body)

    if borked:
        cb.commit_set_status(commit_hash, 'failure', description='PR introduced new issues',
                target_url=report_url, context='gentoo-ci')
    elif pre_borked:
        cb.commit_set_status(commit_hash, 'success', description='No new issues found',
                target_url=report_url, context='gentoo-ci')
    else:
        cb.commit_set_status(commit_hash, 'success', description='All pkgcheck QA checks passed',
                target_url=report_url, context='gentoo-ci')


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
