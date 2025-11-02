#!/usr/bin/env python

import os
import os.path
import sys

from codebergapi import CodebergAPI


def main(commit_hash, stat, desc):
    CODEBERG_TOKEN_FILE = os.environ['CODEBERG_TOKEN_FILE']
    (owner, repo) = os.environ['CODEBERG_REPO'].split('/')

    with open(CODEBERG_TOKEN_FILE) as f:
        token = f.read().strip()

    c = CodebergAPI(owner, repo, token)
    c.commit_set_status(commit_hash, stat, description=desc, context='gentoo-ci')


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
