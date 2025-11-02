#!/usr/bin/env python
# Scan open pull requests, update their statuses and print the next
# one for processing (if any).

import errno
import os
import pickle
import sys
from datetime import datetime

from codebergapi import CodebergAPI


def main():
    CODEBERG_USERNAME = os.environ['CODEBERG_USERNAME']
    CODEBERG_TOKEN_FILE = os.environ['CODEBERG_TOKEN_FILE']
    (owner, repo) = os.environ['CODEBERG_REPO'].split('/')
    PULL_REQUEST_DB = os.environ['CODEBERG_PR_DB']

    with open(CODEBERG_TOKEN_FILE) as f:
        token = f.read().strip()

    db = {}
    try:
        with open(PULL_REQUEST_DB, 'rb') as f:
            db = pickle.load(f)
    except (IOError, OSError) as e:
        if e.errno != errno.ENOENT:
            raise

    cb = CodebergAPI(owner, repo, token)

    to_process = []

    for pr in cb.pulls():
        # skip PRs marked noci
        prnum = pr['number']
        sha = pr['head']['sha']
        if any(x['name'] == 'noci' for x in pr['labels']):
            print(f'{prnum}: noci', file=sys.stderr)

            # if it made it to the cache, we probably need to wipe
            # pending status
            if prnum in db:
                statuses = cb.commit_statuses(sha)
                for status in statuses:
                    # skip foreign statuses
                    if status['creator']['login'] != CODEBERG_USERNAME:
                        continue
                    # if it's pending, mark it done
                    if status['status'] == 'pending':
                        cb.commit_set_status(
                            sha,
                            'success',
                            description='Checks skipped due to [noci] label',
                            context='gentoo-ci',
                        )
                    break
                del db[prnum]

            continue

        # if it's not cached, get its status
        if prnum not in db:
            print(f'{prnum}: updating status ...', file=sys.stderr)
            statuses = cb.commit_statuses(sha)
            for status in statuses:
                # skip foreign statuses
                if status['creator']['login'] != CODEBERG_USERNAME:
                    continue
                # if it's not pending, mark it done
                if status['status'] == 'pending':
                    db[prnum] = ''
                    print(f'{prnum}: found pending', file=sys.stderr)
                else:
                    db[prnum] = sha
                    print(f'{prnum}: at {sha}', file=sys.stderr)
                break
            else:
                db[prnum] = ''
                print(f'{prnum}: unprocessed', file=sys.stderr)

        if db.get(prnum, '') != sha:
            to_process.append(pr)

    to_process = sorted(to_process,
            key=lambda x: (not any(x['name'] == 'priority-ci' for x in pr['labels']), datetime.fromisoformat(x['updated_at'])))
    for i, pr in enumerate(to_process):
        prnum = pr['number']
        sha = pr['head']['sha']
        if i == 0:
            desc = 'QA checks in progress...'
            db[prnum] = sha
        else:
            desc = 'QA checks pending. Currently {}. in queue.'.format(i)
        cb.commit_set_status(
            sha,
            'pending',
            description=desc,
            context='gentoo-ci'
        )

        print(f'{prnum}: {db.get(prnum, "") or '(none)'} -> {sha}',
              file=sys.stderr)

    with open(PULL_REQUEST_DB + '.tmp', 'wb') as f:
        pickle.dump(db, f)
    os.rename(PULL_REQUEST_DB + '.tmp', PULL_REQUEST_DB)

    if to_process:
        print(to_process[0]['number'])

    return 0


if __name__ == '__main__':
    sys.exit(main())
