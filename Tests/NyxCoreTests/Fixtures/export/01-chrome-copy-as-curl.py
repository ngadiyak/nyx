import requests

response = requests.request(
    "POST",
    "https://api.example.com/v1/messages",
    headers={
        "accept": "*/*",
        "accept-language": "en-US,en;q=0.9",
        "cache-control": "no-cache",
        "content-type": "application/json",
        "origin": "https://app.example.com",
        "pragma": "no-cache",
        "priority": "u=1, i",
        "referer": "https://app.example.com/",
        "sec-ch-ua": "\"Chromium\";v=\"128\", \"Not;A=Brand\";v=\"24\"",
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": "\"macOS\"",
        "sec-fetch-dest": "empty",
        "sec-fetch-mode": "cors",
        "sec-fetch-site": "same-site",
    },
    json={
        "model": "claude-opus",
        "stream": True,
        "messages": [
            {
                "role": "user",
                "content": "hi\nthere",
            },
        ],
    },
)

print(response.status_code, response.text)
# not translated: --compressed
