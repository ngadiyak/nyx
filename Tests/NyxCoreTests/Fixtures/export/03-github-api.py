import os
import requests

response = requests.request(
    "GET",
    "https://api.github.com/repos/nyx/nyx/issues",
    params={
        "state": "open",
        "per_page": "100",
    },
    headers={
        "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    },
    allow_redirects=True,
)

print(response.status_code, response.text)
