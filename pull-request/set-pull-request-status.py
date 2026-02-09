#!/usr/bin/env python

import os
import os.path
import sys

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


def main(forge, commit_hash, stat, desc):
    if forge == "github":
        set_github_pr_status(commit_hash, stat, desc)
    elif forge == "codeberg":
        set_codeberg_pr_status(commit_hash, stat, desc)


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
