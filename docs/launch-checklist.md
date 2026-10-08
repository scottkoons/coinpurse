# CoinPurse launch checklist

Steps that need Scott's own logins.  Claude does everything else.

## 1. Support email: coinpurse@yetignome.com (free, Zoho Mail)

This gives CoinPurse its own inbox, separate from your personal and CMB email.  The yetignome.com domain is at GoDaddy and already sends mail through Resend (on the `send.yetignome.com` subdomain), and nothing receives mail for it yet, so there is nothing to conflict with.

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

Do not delete or change the existing `send` and `resend._domainkey` records.  Those send the sign-in codes.

## 2. Vercel settings (project qr-locker, team cmbrew)

Open the project, then **Settings**, then **Environment Variables**.

1. **Check `AUTH_SECRET`.**  It must exist for Production and be a long random value (at least 32 characters).  If it is missing or short, create one by running this command and pasting the output as the value:
   ```bash
   openssl rand -base64 48
   ```
   Changing it signs everyone out once; they sign back in with an email code.  The new server refuses to start without it, on purpose.
2. **Add `REVIEW_EMAIL`** = `appreview@yetignome.com` and **`REVIEW_CODE`** = any 6 digits you choose.  This is the account Apple's reviewer signs in with.  The fixed code works for that one address only, and no email is sent to it.

The variables Coin Purse needs are `COINPURSE_PRIVATE_READ_WRITE_TOKEN`, `AUTH_SECRET`, `RESEND_API_KEY`, `REVIEW_EMAIL` and `REVIEW_CODE`.

## 3. Move pictures to private storage (done)

Production has used the private Blob store (`coinpurse-private`) since 2026-10-05.  Pictures are only reachable through links the server signs, which expire within two days.  The server no longer has a public mode or any move jobs.

On 2026-10-08 the old public Blob store was emptied and deleted, and `ADMIN_EMAILS` and `COINPURSE_STORE` were removed from Vercel.  Nothing is left to do here.

## 3b. Extra protection for sign-in (recommended)

The server already limits codes and guesses per email address.  As a second layer, add a Vercel Firewall rate limit: **Firewall**, then **Add Rule**, path starts with `/api/auth/`, rate limit 20 requests per minute per IP, action Deny.

## 4. App Store Connect (later, when the app is ready for TestFlight)

Claude will ask before each of these:

- Create the app record with bundle ID `com.yetignome.coinpurse`.
- Privacy answers: Email Address and Photos, both "linked to the user", used only for "App Functionality", no tracking.
- Support URL `/support` and privacy policy URL `/privacy` on the CoinPurse web address.
- Reviewer notes: sign in with `REVIEW_EMAIL` and `REVIEW_CODE`.  After the app is approved, you can remove both variables; set them again for each future review.
