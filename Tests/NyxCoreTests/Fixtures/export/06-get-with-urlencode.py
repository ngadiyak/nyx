import requests

response = requests.request(
    "GET",
    "https://api.example.com/search",
    params={
        "q": "hello world",
        "lang": "en",
    },
    headers={
        "Accept": "application/json",
    },
)

print(response.status_code, response.text)
# not translated: -s, -S
