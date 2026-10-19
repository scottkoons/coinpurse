"""The purse the website film starts with (local test server only).  The film
adds the gift card, the voice note, the parking spot and the badge itself."""
import json, os, urllib.request, uuid
B = os.environ.get('BASE', 'http://localhost:3003')

def call(method, path, body=None, ctype='application/json'):
    data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(B + path, data=data, method=method, headers={'content-type': ctype})
    return json.load(urllib.request.urlopen(req))

# Top of the purse first; added in reverse so the first one ends up on top.
coins = [
    ("Tailgate tickets", "Lot opens 9 AM", ['ticket-1.jpg', 'ticket-2.jpg'], 2),
    ("Email Jim back", "Email jim@example.com about the patio quote, or call 719-555-0142.", [], 0),
    ("Grocery list", "", ['grocery-note.jpg'], 3),
    ("Garage code", "4471", [], 1),
]
for title, notes, pictures, accent in reversed(coins):
    cid = str(uuid.uuid4())
    call('POST', '/api/coins', {"id": cid, "title": title, "notes": notes, "accent": accent})
    for i, name in enumerate(pictures):
        with open('img/' + name, 'rb') as f:
            call('POST', f'/api/coins/{cid}/' + ('image' if i == 0 else 'attachments'), f.read(), 'image/jpeg')
print([c['title'] for c in call('GET', '/api/coins')['coins']])
