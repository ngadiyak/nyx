curl -X POST https://api.example.com/v1/photos \
  -H 'accept: application/json' \
  -F file=@photo.jpg \
  -F 'meta={"a":1};type=application/json'
