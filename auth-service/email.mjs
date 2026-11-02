import { AppError } from './auth-service.mjs'

export function isEmailConfigured(env = process.env) {
  return Boolean(env.SENDGRID_API_KEY && env.SENDGRID_FROM_EMAIL)
}

export async function sendEmail(message, env = process.env) {
  if (!isEmailConfigured(env)) {
    throw new AppError(503, 'Credential email delivery is not configured.', 'EMAIL_NOT_CONFIGURED')
  }

  let response
  try {
    response = await fetch('https://api.sendgrid.com/v3/mail/send', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.SENDGRID_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        personalizations: [{ to: [{ email: message.to }] }],
        from: {
          email: env.SENDGRID_FROM_EMAIL,
          name: env.SENDGRID_FROM_NAME || 'DMS Support',
        },
        subject: message.subject,
        content: [
          { type: 'text/plain', value: message.text },
          { type: 'text/html', value: message.html },
        ],
      }),
    })
  } catch {
    throw new AppError(502, 'The credential email could not be delivered. Please try again.', 'EMAIL_DELIVERY_FAILED')
  }

  if (response.status !== 202) {
    throw new AppError(502, 'The credential email could not be delivered. Please try again.', 'EMAIL_DELIVERY_FAILED')
  }
}
