curl -G 'https://api.example.com/search' \
  --data-urlencode "q=hello world" \
  --data-urlencode 'lang=en' \
  -H 'Accept: application/json' \
  -sS
