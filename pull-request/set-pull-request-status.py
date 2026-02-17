#!/usr/bin/env python

import errno
import os
import os.path
import sys
import pickle

import github
from codebergapi import CodebergAPI


def set_codeberg_pr_status(commit_hash, stat, desc):
    CODEBERG_TOKEN_FILE = os.environ["CODEBERG_TOKEN_FILE"]
    (owner, repo) = os.environ["CODEBERG_REPO"].split("/")

    with open(CODEBERG_TOKEN_FILE) as f:
        token = f.read().strip()

    with CodebergAPI(owner, repo, token) as cb:
        cb.commit_set_status(commit_hash, stat, description=desc, context="gentoo-ci")


def set_github_pr_status(commit_hash, stat, desc):
    GITHUB_USERNAME = os.environ["GITHUB_USERNAME"]
    GITHUB_TOKEN_FILE = os.environ["GITHUB_TOKEN_FILE"]
    GITHUB_REPO = os.environ["GITHUB_REPO"]

    with open(GITHUB_TOKEN_FILE) as f:
        token = f.read().strip()

    g = github.Github(GITHUB_USERNAME, token, per_page=50)
    r = g.get_repo(GITHUB_REPO)
    c = r.get_commit(commit_hash)

    c.create_status(stat, description=desc, context="gentoo-ci")


def commit_hash_from_db(pr_id):
    try:
        with open(os.environ["PULL_REQUEST_DB"], "rb") as f:
            db = pickle.load(f)
            return db.get(pr_id)
    except (IOError, OSError) as e:
        if e.errno != errno.ENOENT:
            raise


def main(pr_id, stat, desc):
    forge = pr_id.split("/")[0]
    commit_hash = commit_hash_from_db(pr_id)
    if commit_hash is None:
        return 0
    if forge == "github":
        set_github_pr_status(commit_hash, stat, desc)
    elif forge == "codeberg":
        set_codeberg_pr_status(commit_hash, stat, desc)
    return 0

if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
