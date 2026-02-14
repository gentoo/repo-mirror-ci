import requests
from typing import Generator


class CodebergAPI:
    def __init__(self, owner: str, repo: str, token: str):
        self.owner = owner
        self.repo = repo
        self.token = token

    def __enter__(self):
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"token {self.token}",
                "Content-Type": "application/json",
            }
        )
        self.session.hooks = {
            "response": lambda r, *args, **kwargs: r.raise_for_status()
        }
        return self

    def __exit__(self, exc_type: object, exc_val: object, exc_tb: object) -> None:
        self.session.close()

    @property
    def repos_baseurl(self) -> str:
        return f"https://codeberg.org/api/v1/repos/{self.owner}/{self.repo}"

    @property
    def orgs_baseurl(self) -> str:
        return "https://codeberg.org/api/v1/orgs"

    @property
    def teams_baseurl(self) -> str:
        return "https://codeberg.org/api/v1/teams"

    def _get_paginated(self, url) -> Generator[None, dict, None]:
        r = self.session.get(url, params={"limit": 100})
        yield from r.json()
        if "next" not in r.links:
            return
        next_url = r.links["next"]["url"]
        while True:
            r = self.session.get(next_url)
            yield from r.json()
            if "next" not in r.links:
                break
            next_url = r.links["next"]["url"]

    def pulls(self, state="open") -> Generator[None, dict, None]:
        """
        state must be one of: open, closed, all
        """
        return self._get_paginated(f"{self.repos_baseurl}/pulls?state={state}")

    def set_pr_title(self, pr_id: int, title: str) -> None:
        self.session.patch(f"{self.repos_baseurl}/pulls/{pr_id}", json={"title": title})

    def add_pr_labels(self, pr_id: int, labels: list[int]) -> None:
        self.session.patch(
            f"{self.repos_baseurl}/pulls/{pr_id}", json=({"labels": labels})
        )

    def labels(self) -> list[dict]:
        return self.session.get(f"{self.repos_baseurl}/labels").json()

    def commits(self, pr_id: int) -> list[dict]:
        # https://codeberg.org/api/swagger#/repository/repoGetPullRequestCommits
        return self.session.get(f"{self.repos_baseurl}/pulls/{pr_id}/commits").json()

    def commit_statuses(self, sha):
        # /repos/{owner}/{repo}/statuses/{sha}
        return self.session.get(f"{self.repos_baseurl}/statuses/{sha}").json()

    def commit_set_status(
        self, sha, state, description=None, target_url=None, context=None
    ):
        # /repos/{owner}/{repo}/statuses/{sha}
        body = {
            "context": context,
            "state": state,
            "description": description,
            "target_url": target_url,
        }
        self.session.post(f"{self.repos_baseurl}/statuses/{sha}", json=body)

    def files(self, pr_id: int) -> list[dict]:
        return self.session.get(f"{self.repos_baseurl}/pulls/{pr_id}/files").json()

    def get_reviews(self, pr_id: int) -> list[dict]:
        return self.session.get(f"{self.repos_baseurl}/pulls/{pr_id}/reviews").json()

    def create_review(self, pr_id: int, comment: str) -> None:
        # Does not appear to be possible to simply post comments
        # https://codeberg.org/api/swagger#/repository/repoCreatePullReview
        self.session.post(
            f"{self.repos_baseurl}/pulls/{pr_id}/reviews",
            json={
                "body": comment,
            },
        )

    def delete_review(self, pr_id: int, review_id: int) -> None:
        self.session.delete(f"{self.repos_baseurl}/pulls/{pr_id}/reviews/{review_id}")

    def teams(self, org: str) -> Generator[None, dict, None]:
        # https://codeberg.org/api/swagger#/organization/orgListTeams
        #
        # It *should* support pagination, but apparently it's not
        # providing the Link header to the next page. We do get the
        # X-Total-Count header which lets us work out the number of
        # pages ourselves.
        url = f"{self.orgs_baseurl}/{org}/teams/"
        params = {"limit": 100, "page": 1}
        r = self.session.get(url, params=params)
        total = int(r.headers["X-Total-Count"])
        t = r.json()
        yield from t

        count = len(t)
        while count < total:
            params["page"] += 1
            r = self.session.get(url, params=params)
            t = r.json()
            yield from t
            count += len(t)

    def create_team(self, org: str, name: str, description: str) -> dict:
        # https://codeberg.org/api/swagger#/organization/orgCreateTeam
        # The docs are buggy, see https://codeberg.org/forgejo/forgejo/issues/9881
        r = self.session.post(
            f"{self.orgs_baseurl}/{org}/teams",
            json={
                "name": name,
                "description": description,
                "includes_all_repositories": True,
                "permission": "write",
                "units": [
                    "repo.code",
                    "repo.issues",
                    "repo.pulls",
                    "repo.releases",
                    "repo.wiki",
                    "repo.ext_wiki",
                    "repo.ext_issues",
                    "repo.projects",
                    "repo.packages",
                    "repo.actions",
                ],
                "units_map": {
                    "repo.actions": "none",
                    "repo.code": "read",
                    "repo.ext_issues": "read",
                    "repo.ext_wiki": "read",
                    "repo.issues": "none",
                    "repo.packages": "none",
                    "repo.projects": "none",
                    "repo.pulls": "write",
                    "repo.releases": "none",
                    "repo.wiki": "none",
                },
                "can_create_org_repo": False,
            },
        )
        return r.json()

    def team_members(self, team_id: int) -> Generator[None, dict, None]:
        return self._get_paginated(f"{self.teams_baseurl}/{team_id}/members")

    def team_add_member(self, team_id: int, username: str) -> None:
        # https://codeberg.org/api/swagger#/organization/orgAddTeamMember
        self.session.put(f"{self.teams_baseurl}/{team_id}/members/{username}")

    def team_remove_member(self, team_id: int, username: str) -> None:
        # https://codeberg.org/api/swagger#/organization/orgRemoveTeamMember
        self.session.delete(f"{self.teams_baseurl}/{team_id}/members/{username}")

    def team_repos(self, team_id: int) -> Generator[None, dict, None]:
        # https://codeberg.org/api/swagger#/organization/orgListTeamRepos
        return self._get_paginated(f"{self.teams_baseurl}/{team_id}/repos")

    def org_members(self, org: str) -> Generator[None, dict, None]:
        return self._get_paginated(f"{self.orgs_baseurl}/{org}/members")

    def org_delete_team(self, team_id: int) -> None:
        # https://codeberg.org/api/swagger#/organization/orgDeleteTeam
        self.session.delete(f"{self.teams_baseurl}/{team_id}")

    def org_remove_member(self, org: str, username: str) -> None:
        # https://codeberg.org/api/swagger#/organization/orgDeleteMember
        self.session.delete(f"{self.orgs_baseurl}/{org}/members/{username}")
