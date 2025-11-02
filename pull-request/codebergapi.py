import requests
import json
from dataclasses import dataclass

@dataclass
class CodebergAPI:
    owner: str
    repo: str
    token: str

    @property
    def headers(self):
        return {
            "Authorization": f"token {self.token}",
            "Accept": "application/json"
        }

    @property
    def repos_baseurl(self):
        return f"https://codeberg.org/api/v1/repos/{self.owner}/{self.repo}"

    def _get(self, url, params={}):
        resp = requests.get(url, params=params, headers=self.headers)
        resp.raise_for_status()
        return json.loads(resp.content)

    def _post(self, url, body):
        resp = requests.post(url, headers=self.headers, json=body)
        resp.raise_for_status()

    def _delete(self, url):
        resp = requests.delete(url, headers=self.headers)
        resp.raise_for_status()

    def _patch(self, url, body):
        resp = requests.patch(url, headers=self.headers, json=body)
        resp.raise_for_status()

    def pulls_page(self, page):
        return self._get(
            f"{self.repos_baseurl}/pulls",
            params={
                "page": page,
            }
        )

    def pulls(self):
        page = 1
        while True:
            pulls = self.pulls_page(page)
            if not pulls:
                break
            yield from pulls
            page += 1

    def commit_statuses(self, sha):
        # /repos/{owner}/{repo}/statuses/{sha}
        return self._get(f"{self.repos_baseurl}/statuses/{sha}")

    def commit_set_status(self, sha, state, description=None, target_url=None, context=None):
        # /repos/{owner}/{repo}/statuses/{sha}
        body = {
            "context": context,
            "state": state,
            "description": description,
            "target_url": target_url,
        }
        return self._post(f"{self.repos_baseurl}/statuses/{sha}", body)

    def get_reviews(self, pr_id):
        return self._get(f"{self.repos_baseurl}/pulls/{pr_id}/reviews")

    def create_review(self, pr_id, comment):
        # https://codeberg.org/api/swagger#/repository/repoCreatePullReview
        url = f"{self.repos_baseurl}/pulls/{pr_id}/reviews"
        body = {
            "body": comment,
        }
        self._post(url, body)

    def delete_review(self, pr_id, review_id):
        self._delete(f"{self.repos_baseurl}/pulls/{pr_id}/reviews/{review_id}")
