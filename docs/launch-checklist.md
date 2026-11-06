# CoinPurse launch checklist

Steps that need Scott's own logins.  Claude does everything else.

Coin Purse has no server, no accounts and no sign in.  Every coin lives only on the iPhone.  Vercel only hosts the website (static files).

## 1. Support email: coinpurse@yetignome.com (free, Zoho Mail)

This gives CoinPurse its own inbox, separate from your personal and CMB email.  The yetignome.com domain is at GoDaddy, and nothing receives mail for it yet, so there is nothing to conflict with.

1. Go to zoho.com/mail, choose **Forever Free**, and sign up with "I already own a domain": `yetignome.com`.
2. Zoho asks you to prove you own the domain with a TXT record.  In GoDaddy, open yetignome.com, then **DNS**, then **Add New Record**, and paste the TXT value Zoho shows.  Click Verify in Zoho.
3. Create the user `coinpurse` so the address is `coinpurse@yetignome.com`.
4. In GoDaddy DNS, add the records Zoho lists for mail delivery:
   - MX `@` → `mx.zoho.com` priority 10
   - MX `@` → `mx2.zoho.com` priority 20
   - MX `@` → `mx3.zoho.com` priority 50
   - TXT `@` → `v=spf1 include:zohomail.com ~all`
   - The DKIM TXT record Zoho generates for you.
5. Install the Zoho Mail app on your phone and sign in as coinpurse@yetignome.com.  It stays separate from your other mail.
6. Send a test email to coinpurse@yetignome.com from your personal address.

The `send` and `resend._domainkey` records sent the old sign-in codes.  Coin Purse no longer uses them; remove them only if nothing else of yours sends mail through Resend.

## 2. Vercel cleanup (project qr-locker, team cmbrew)

Open the project, then **Settings**, then **Environment Variables**, and delete the leftovers from the old server.  Nothing reads them any more:

`AUTH_SECRET`, `RESEND_API_KEY`, `RESEND_FROM`, `REVIEW_EMAIL`, `APP_URL`, `COINPURSE_URL`, `COINPURSE_RETURN_LINK`, `COINPURSE_PIN`, `COINPURSE_TOKEN`

Keep the project itself and the coinpurse.yetignome.com domain: they serve the website.

## 3. App Store Connect (later, when the app is ready for TestFlight)

Claude will ask before each of these:

- Create the app record with bundle ID `com.yetignome.coinpurse`.
- Privacy answers: **Data Not Collected** (see `docs/app-store-listing.md`).
- Support URL `/support` and privacy policy URL `/privacy` on the CoinPurse web address.
- Reviewer notes: no sign in or demo account is needed (see `docs/app-store-listing.md`).
