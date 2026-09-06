const params = new URLSearchParams();
params.append("q", "hello world");
params.append("lang", "en");

fetch("https://api.example.com/search" + "?" + params.toString(), {
  method: "GET",
  headers: {
    "Accept": "application/json",
  },
})
  .then((response) => response.json())
  .then((data) => console.log(data))
  .catch((error) => console.error(error));
// not translated: -s, -S
