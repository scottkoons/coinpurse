async function sendSignInCodeEmail({ to, code }) {
  const key = process.env.RESEND_API_KEY;
  if (!key) throw new Error('RESEND_API_KEY not configured');
  const from = process.env.RESEND_FROM || 'CoinPurse <onboarding@resend.dev>';
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + key,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from,
      to: [to],
      subject: 'Your CoinPurse code: ' + code,
      html:
        '<p>Your CoinPurse sign-in code is:</p>' +
        '<p style="font-size:28px;letter-spacing:0.2em;font-weight:700">' + code + '</p>' +
        '<p>It expires in 15 minutes. If you did not ask for this, ignore the email.</p>',
      text:
        'Your CoinPurse sign-in code is: ' + code + '\n\n' +
        'It expires in 15 minutes. If you did not ask for this, ignore the email.\n',
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = data.message || data.error || ('Email failed ' + res.status);
    throw new Error(msg);
  }
  return data;
}

/** @deprecated Prefer sendSignInCodeEmail — Gmail often drops long magic-link URLs. */
async function sendMagicLinkEmail({ to, url }) {
  const key = process.env.RESEND_API_KEY;
  if (!key) throw new Error('RESEND_API_KEY not configured');
  const from = process.env.RESEND_FROM || 'CoinPurse <onboarding@resend.dev>';
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + key,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from,
      to: [to],
      subject: 'CoinPurse sign-in',
      html: `<p>Open CoinPurse with this link (expires in 30 minutes):</p>
<p><a href="${url}">${url}</a></p>
<p>If you did not ask for this, ignore the email.</p>`,
      text: `Open CoinPurse: ${url}\n\nLink expires in 30 minutes.`,
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = data.message || data.error || ('Email failed ' + res.status);
    throw new Error(msg);
  }
  return data;
}

module.exports = { sendSignInCodeEmail, sendMagicLinkEmail };
