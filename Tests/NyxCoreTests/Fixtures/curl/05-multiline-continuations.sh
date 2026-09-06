curl --request POST \
     --url https://api.example.com/v2/search \
     --header 'content-type: application/json' \
     --header 'accept: application/json' \
     --data '{"query":"nyx","limit":25}' \
     --max-time 30 \
     --retry 2 \
     --retry-delay 1 \
     --silent \
     --show-error
