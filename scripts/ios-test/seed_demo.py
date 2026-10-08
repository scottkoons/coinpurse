"""The starting purse for the website film (local test server only)."""
import json, urllib.request, uuid, time
import os
B=os.environ.get('BASE','http://localhost:3000')
tok=json.load(urllib.request.urlopen(urllib.request.Request(B+'/api/auth/verify-code',data=json.dumps({"email":"review@example.com","code":"123456"}).encode(),headers={'content-type':'application/json'})))['token']
H={'authorization':'Bearer '+tok}
def call(method,path,body=None,ctype='application/json'):
    data=body if isinstance(body,bytes) else (json.dumps(body).encode() if body is not None else None)
    r=urllib.request.Request(B+path,data=data,method=method,headers={**H,'content-type':ctype})
    return json.load(urllib.request.urlopen(r))
now=int(time.time()*1000)
# Top of the purse first; created in reverse so the first one ends up on top.
coins=[
 ("Garage code","4471",[],None,0),
 ("Tailgate tickets","Lot opens 9 AM",['ticket-1.jpg','ticket-2.jpg'],None,2),
 ("Coffee gift card","Good Day Coffee, $25",['gift-card-coffee.jpg'],None,5),
 ("Email Jim back","Remind me to email jim@example.com about the patio quote, or call 719-555-0142.",[],None,0),
 ("Grocery list","",['grocery-note.jpg'],None,3),
]
for t,n,ps,pin,acc in reversed(coins):
    cid=str(uuid.uuid4())
    body={"id":cid,"title":t,"notes":n,"accent":acc}
    if pin: body["pin"]=pin
    call('POST','/api/coins',body)
    for j,p in enumerate(ps):
        call('POST',f'/api/coins/{cid}/'+('image' if j==0 else 'attachments'),open('img/'+p,'rb').read(),'image/jpeg')
print([c['title'] for c in call('GET','/api/coins')['coins']])
