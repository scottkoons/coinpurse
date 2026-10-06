"""150 coins (most with pictures) for review@example.com, for speed and memory tests."""
import json, urllib.request, uuid
import os
B=os.environ.get('BASE','http://localhost:3000')
tok=json.load(urllib.request.urlopen(urllib.request.Request(B+'/api/auth/verify-code',data=json.dumps({"email":"review@example.com","code":"123456"}).encode(),headers={'content-type':'application/json'})))['token']
H={'authorization':'Bearer '+tok}
def call(method,path,body=None,ctype='application/json'):
    data=body if isinstance(body,bytes) else (json.dumps(body).encode() if body is not None else None)
    return json.load(urllib.request.urlopen(urllib.request.Request(B+path,data=data,method=method,headers={**H,'content-type':ctype})))
pics=['ticket-1.jpg','parking-b3.jpg','gift-card-coffee.jpg','grocery-note.jpg','conference-badge.jpg','return-label.jpg','ticket-2.jpg']
blobs={p:open('img/'+p,'rb').read() for p in pics}
for i in range(150):
    cid=str(uuid.uuid4())
    call('POST','/api/coins',{"id":cid,"title":f"Coin number {i+1:03d}","notes":f"Note for coin {i+1}","accent":i%6})
    if i%5!=4:
        call('POST',f'/api/coins/{cid}/image',blobs[pics[i%len(pics)]],'image/jpeg')
print(len(call('GET','/api/coins')['coins']),'coins')
