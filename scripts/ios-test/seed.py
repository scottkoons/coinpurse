"""Fills the local test server with 30 coins for review@example.com."""
import json, urllib.request, uuid
import os
B=os.environ.get('BASE','http://localhost:3000')
tok=json.load(urllib.request.urlopen(urllib.request.Request(B+'/api/auth/verify-code',data=json.dumps({"email":"review@example.com","code":"123456"}).encode(),headers={'content-type':'application/json'})))['token']
H={'authorization':'Bearer '+tok}
def call(method,path,body=None,ctype='application/json'):
    data=body if isinstance(body,bytes) else (json.dumps(body).encode() if body is not None else None)
    r=urllib.request.Request(B+path,data=data,method=method,headers={**H,'content-type':ctype})
    return json.load(urllib.request.urlopen(r))
coins=[
 ("Tailgate tickets","Lot opens 9 AM",['ticket-1.jpg','ticket-2.jpg']),("Parking B3","Two slots down from the elevator",['parking-b3.jpg']),
 ("Coffee gift card","Good Day Coffee, $25",['gift-card-coffee.jpg']),("Grocery list","",['grocery-note.jpg']),
 ("DevSummit badge","Hall C, booth 214",['conference-badge.jpg']),("Return label","Drop off by Friday",['return-label.jpg']),
 ("Email Jim back","Remind me I need to email Jim back about the patio quote.",[]),
 ("","I'm parked on the second level of the third garage over, two slots down.",[]),
 ("Wi-Fi password","Guest network: Mountain-Guest",[]),("Dentist","Tuesday at 3:30. Bring the insurance card.",[]),
 ("Hotel confirmation","Confirmation 48213, check in after 4",['ticket-2.jpg']),("Dry cleaning","Ticket 0912",[]),
 ("Locker 17","Combination is on the back",['parking-b3.jpg']),("Kids pickup","Gate 4 at 2:45",[]),
 ("Concert tickets","Section 104, row K",['ticket-1.jpg']),("Pharmacy","Prescription ready Thursday",[]),
 ("Book for Sam","The one about the mountains",[]),("Library card","",['gift-card-coffee.jpg']),
 ("Airport parking","Row 22, Economy lot",['parking-b3.jpg']),("Paint color","Agreeable Gray, eggshell",[]),
 ("Tire pressure","35 front, 33 rear",[]),("Gym check-in","",['conference-badge.jpg']),
 ("Flight","DEN to SFO, 7:40 boarding",['ticket-2.jpg']),("Call the plumber","Before Thursday",[]),
 ("Recipe","Grandma's chili, from the photo",['grocery-note.jpg']),("Seat numbers","14C and 14D",[]),
 ("Package pickup","Locker code 5521",[]),("Museum passes","Two adults",['ticket-1.jpg']),
 ("Brewery order","Two growlers on Friday",[]),("Garage code","4471",[]),
]
for i,(t,n,ps) in enumerate(coins):
    cid=str(uuid.uuid4())
    call('POST','/api/coins',{"id":cid,"title":t,"notes":n,"accent":i%6})
    for j,p in enumerate(ps):
        call('POST',f'/api/coins/{cid}/'+('image' if j==0 else 'attachments'),open('img/'+p,'rb').read(),'image/jpeg')
print(len(call('GET','/api/coins')['coins']),'coins')
