fetch("https://api.github.com/repos/nyx/nyx/issues?state=open&per_page=100", {
  method: "GET",
  headers: {
    "Authorization": `Bearer ${process.env.GITHUB_TOKEN}`,
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  },
  redirect: "follow",
})
  .then((response) => response.json())
  .then((data) => console.log(data))
  .catch((error) => console.error(error));
