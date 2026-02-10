#!/usr/bin/env python
# Scan open pull requests, update their statuses and print the next
# one for processing (if any).

from __future__ import print_function

import errno
import os
import pickle
import sys
from datetime import datetime

import github
from codebergapi import CodebergAPI


def scan_codeberg(db: dict):
    CODEBERG_USERNAME = os.environ["CODEBERG_USERNAME"]
    CODEBERG_TOKEN_FILE = os.environ["CODEBERG_TOKEN_FILE"]
    (owner, repo) = os.environ["CODEBERG_REPO"].split("/")

    with open(CODEBERG_TOKEN_FILE) as f:
        token = f.read().strip()

    with CodebergAPI(owner, repo, token) as cb:
        to_process = []
        for pr in cb.pulls():
            pr_key = f"codeberg/{pr['number']}"
            sha = pr["head"]["sha"]

            # skip PRs marked noci
            if any(x["name"] == "noci" for x in pr["labels"]):
                print(f"{pr_key}: noci", file=sys.stderr)

                # if it made it to the cache, we probably need to wipe
                # pending status
                if pr_key in db:
                    statuses = cb.commit_statuses(sha)
                    for status in statuses:
                        # skip foreign statuses
                        if status["creator"]["login"] != CODEBERG_USERNAME:
                            continue
                        # if it's pending, mark it done
                        if status["status"] == "pending":
                            cb.commit_set_status(
                                sha,
                                "success",
                                description="Checks skipped due to [noci] label",
                                context="gentoo-ci",
                            )
                        break
                    del db[pr_key]

                continue

            # if it's not cached, get its status
            if pr_key not in db:
                print(f"{pr_key}: updating status ...", file=sys.stderr)
                statuses = cb.commit_statuses(sha)
                for status in statuses:
                    # skip foreign statuses
                    if status["creator"]["login"] != CODEBERG_USERNAME:
                        continue
                    # if it's not pending, mark it done
                    if status["status"] == "pending":
                        db[pr_key] = ""
                        print(f"{pr_key}: found pending", file=sys.stderr)
                    else:
                        db[pr_key] = sha
                        print(f"{pr_key}: at {sha}", file=sys.stderr)
                    break
                else:
                    db[pr_key] = ""
                    print(f"{pr_key}: unprocessed", file=sys.stderr)

            if db.get(pr_key, "") != sha:
                to_process.append(pr)

        to_process = sorted(
            to_process,
            key=lambda x: (
                not any(x["name"] == "priority-ci" for x in pr["labels"]),
                datetime.fromisoformat(x["updated_at"]),
            ),
        )
        queue = []
        for i, pr in enumerate(to_process):
            pr_key = f"codeberg/{pr['number']}"
            sha = pr["head"]["sha"]
            if i == 0:
                desc = "QA checks in progress..."
                db[pr_key] = sha
            else:
                desc = "QA checks pending. Currently {}. in queue.".format(i)
            cb.commit_set_status(sha, "pending", description=desc, context="gentoo-ci")

            print(
                f"{pr_key}: {db.get(pr_key, '') or '(none)'} -> {sha}", file=sys.stderr
            )
            queue.append(pr_key)
        return queue


def scan_github(db: dict, queue_len: int):
    """
    Given a db of knowns PRs, inspect open PRs, update commit
    statuses, and update the db accordingly. Return a list of
    outstanding PRs to process.
    """
    GITHUB_USERNAME = os.environ["GITHUB_USERNAME"]
    GITHUB_TOKEN_FILE = os.environ["GITHUB_TOKEN_FILE"]
    GITHUB_REPO = os.environ["GITHUB_REPO"]

    with open(GITHUB_TOKEN_FILE) as f:
        token = f.read().strip()

    g = github.Github(GITHUB_USERNAME, token, per_page=250)
    r = g.get_repo(GITHUB_REPO)

    to_process = []

    for pr in r.get_pulls():
        # Preferred db key
        pr_key = f"github/{pr.number}"
        # support pr.number as implicitly a github PR, but default to pr_key
        db_key = pr.number if pr.number in db else pr_key
        # skip PRs marked noci
        if any(x.name == "noci" for x in pr.labels):
            print(f"{pr_key}: noci", file=sys.stderr)

            # if it made it to the cache, we probably need to wipe
            # pending status
            if db_key in db:
                commit = r.get_commit(pr.head.sha)
                for status in commit.get_statuses():
                    # skip foreign statuses
                    if status.creator.login != GITHUB_USERNAME:
                        continue
                    # if it's pending, mark it done
                    if status.state == "pending":
                        commit.create_status(
                            context="gentoo-ci",
                            state="success",
                            description="Checks skipped due to [noci] label",
                        )
                    break
                del db[db_key]

            continue

        # if it's not cached, get its status
        if db_key not in db:
            print(f"{pr_key}: updating status ...", file=sys.stderr)
            commit = r.get_commit(pr.head.sha)
            for status in commit.get_statuses():
                # skip foreign statuses
                if status.creator.login != GITHUB_USERNAME:
                    continue
                # if it's not pending, mark it done
                if status.state != "pending":
                    db[pr_key] = commit.sha
                    print(f"{pr_key}: at {commit.sha}", file=sys.stderr)
                else:
                    db[pr_key] = ""
                    print(f"{pr_key}: found pending", file=sys.stderr)
                break
            else:
                db[db_key] = ""
                print(f"{pr_key}: unprocessed", file=sys.stderr)

        if db.get(db_key, "") != pr.head.sha:
            to_process.append(pr)

    to_process = sorted(
        to_process,
        key=lambda x: (
            not any(x.name == "priority-ci" for x in x.labels),
            x.updated_at,
        ),
    )
    queue = []
    for i, pr in enumerate(to_process):
        pr_key = f"github/{pr.number}"
        db_key = pr.number if pr.number in db else pr_key
        commit = r.get_commit(pr.head.sha)
        if i + queue_len == 0:
            desc = "QA checks in progress..."
            db[db_key] = commit.sha
        else:
            desc = f"QA checks pending. Currently {i + queue_len}. in queue."
        commit.create_status(context="gentoo-ci", state="pending", description=desc)

        print(
            f"{pr_key}: {db.get(db_key, '') or '(none)'} -> {pr.head.sha}",
            file=sys.stderr,
        )
        queue.append(pr_key)

    return queue


def main():
    PULL_REQUEST_DB = os.environ["PULL_REQUEST_DB"]

    db = {}
    try:
        with open(PULL_REQUEST_DB, "rb") as f:
            db = pickle.load(f)
    except (IOError, OSError) as e:
        if e.errno != errno.ENOENT:
            raise

    queue = scan_codeberg(db)
    queue.extend(scan_github(db, len(queue)))

    with open(PULL_REQUEST_DB + ".tmp", "wb") as f:
        pickle.dump(db, f)
    os.rename(PULL_REQUEST_DB + ".tmp", PULL_REQUEST_DB)

    if queue:
        print(queue[0])

    return 0


if __name__ == "__main__":
    sys.exit(main())
