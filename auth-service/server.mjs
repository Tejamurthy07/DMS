import { createServer } from 'node:http'
import { randomBytes } from 'node:crypto'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { AppError, createAuthHandlers, createRateLimiter, normalizeEmail } from './auth-service.mjs'
import { isEmailConfigured, sendEmail } from './email.mjs'
import { createSalesforceRepository, SalesforceClient } from './salesforce.mjs'
import { hashPassword } from './passwords.mjs'

const MAX_BODY_BYTES = 16 * 1024
const serverEnv = process.env

function sendJson(response, status, body, origin) {
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    ...(origin ? { 'Access-Control-Allow-Origin': origin, 'Vary': 'Origin' } : {}),
  })
  response.end(JSON.stringify(body))
}

async function readJson(request) {
  const chunks = []
  let byteLength = 0
  for await (const chunk of request) {
    byteLength += chunk.length
    if (byteLength > MAX_BODY_BYTES) {
      throw new AppError(413, 'Request body is too large.')
    }
    chunks.push(chunk)
  }
  if (!byteLength) {
    return {}
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'))
  } catch {
    throw new AppError(400, 'Request body must be valid JSON.')
  }
}

function getBearerToken(request) {
  const value = request.headers.authorization || ''
  const match = /^Bearer ([A-Za-z0-9._~-]+)$/.exec(value)
  return match?.[1] || ''
}

function safeEmailError(error) {
  return error instanceof AppError
    ? error
    : new AppError(500, 'The request could not be completed.', 'INTERNAL_ERROR')
}

export async function createDmsServer({
  env = serverEnv,
  repository,
  sendMail = (message) => sendEmail(message, env),
  authorizeAdmin,
  logger = console,
} = {}) {
  if (!repository) {
    const salesforce = new SalesforceClient(env)
    repository = createSalesforceRepository(salesforce)
    authorizeAdmin = authorizeAdmin || ((token) => salesforce.authorizeAdmin(token))
  }

  if (!repository.dummyPasswordHash) {
    repository.dummyPasswordHash = await hashPassword(randomBytes(32).toString('base64url'))
  }

  const webOrigin = env.WEB_ORIGIN
  const loginUrl = env.DMS_LOGIN_URL
  if (!webOrigin || !loginUrl) {
    throw new Error('WEB_ORIGIN and DMS_LOGIN_URL must be configured.')
  }
  const parsedLoginUrl = new URL(loginUrl)
  if (parsedLoginUrl.protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(parsedLoginUrl.hostname)) {
    throw new Error('DMS_LOGIN_URL must use HTTPS outside local development.')
  }

  const handlers = createAuthHandlers({
    repository,
    sendEmail: sendMail,
    authorizeAdmin: authorizeAdmin || (async () => {
      throw new AppError(403, 'An authorized administrator session is required.', 'ADMIN_UNAUTHORIZED')
    }),
    warnEmailFailure: (code) => logger.warn('DMS password-reset email delivery failed:', code),
    loginUrl,
    sessionTtlMs: Number(env.SESSION_TTL_HOURS || 8) * 60 * 60 * 1000,
    resetTtlMs: Number(env.RESET_TOKEN_TTL_MINUTES || 30) * 60 * 1000,
  })
  const loginLimiter = createRateLimiter()
  const loginIpLimiter = createRateLimiter({ limit: 30 })
  const resetLimiter = createRateLimiter({ limit: 3 })
  const resetIpLimiter = createRateLimiter({ limit: 10 })

  const server = createServer(async (request, response) => {
    const origin = request.headers.origin
    if (origin && origin !== webOrigin) {
      sendJson(response, 403, { success: false, message: 'This origin is not allowed.' })
      return
    }
    if (request.method === 'OPTIONS') {
      response.writeHead(204, {
        'Access-Control-Allow-Origin': webOrigin,
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type',
        'Access-Control-Max-Age': '600',
        Vary: 'Origin',
      })
      response.end()
      return
    }

    const requestUrl = new URL(request.url, 'http://localhost')
    const path = requestUrl.pathname
    const remoteAddress = request.socket.remoteAddress || 'unknown'
    try {
      if (request.method === 'GET' && path === '/health') {
        sendJson(response, 200, { status: 'ok', emailConfigured: isEmailConfigured(env) }, origin)
        return
      }
      if (request.method === 'POST' && path === '/api/v1/auth/login') {
        if (loginIpLimiter.isLimited(remoteAddress)) {
          throw new AppError(429, 'Too many sign-in attempts. Try again later.', 'RATE_LIMITED')
        }
        const input = await readJson(request)
        const key = `${remoteAddress}:${normalizeEmail(input.email)}`
        if (loginLimiter.isLimited(key)) {
          throw new AppError(429, 'Too many sign-in attempts. Try again later.', 'RATE_LIMITED')
        }
        try {
          const result = await handlers.login(input)
          loginLimiter.succeed(key)
          loginIpLimiter.succeed(remoteAddress)
          sendJson(response, 200, { success: true, ...result }, origin)
        } catch (error) {
          if (error.code === 'INVALID_CREDENTIALS') {
            loginLimiter.fail(key)
            loginIpLimiter.fail(remoteAddress)
          }
          throw error
        }
        return
      }
      if (request.method === 'POST' && path === '/api/v1/auth/password') {
        const result = await handlers.changePassword(await readJson(request), getBearerToken(request))
        sendJson(response, 200, { success: true, ...result }, origin)
        return
      }
      if (request.method === 'GET' && path === '/api/v1/auth/session') {
        sendJson(response, 200, { success: true, ...(await handlers.getSession(getBearerToken(request))) }, origin)
        return
      }
      if (request.method === 'POST' && path === '/api/v1/auth/logout') {
        sendJson(response, 200, await handlers.logout(getBearerToken(request)), origin)
        return
      }
      if (request.method === 'POST' && path === '/api/v1/auth/forgot-password') {
        if (!isEmailConfigured(env)) {
          throw new AppError(503, 'Password recovery email is temporarily unavailable.', 'EMAIL_NOT_CONFIGURED')
        }
        const input = await readJson(request)
        const resetKey = `${remoteAddress}:${normalizeEmail(input.email)}`
        if (resetIpLimiter.isLimited(remoteAddress) || resetLimiter.isLimited(resetKey)) {
          throw new AppError(429, 'Too many reset requests. Try again later.', 'RATE_LIMITED')
        }
        resetLimiter.fail(resetKey)
        resetIpLimiter.fail(remoteAddress)
        sendJson(response, 202, await handlers.forgotPassword(input), origin)
        return
      }
      if (request.method === 'POST' && path === '/api/v1/auth/reset-password') {
        sendJson(response, 200, await handlers.resetPassword(await readJson(request)), origin)
        return
      }
      if (request.method === 'GET' && path === '/api/v1/admin/distributors') {
        const results = await handlers.searchDistributors(
          requestUrl.searchParams.get('q') || '',
          getBearerToken(request),
        )
        sendJson(response, 200, { success: true, distributors: results }, origin)
        return
      }
      const credentialMatch = /^\/api\/v1\/admin\/distributors\/([a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?)\/credentials$/.exec(path)
      if (request.method === 'POST' && credentialMatch) {
        if (!isEmailConfigured(env)) {
          throw new AppError(503, 'Credential email delivery is not configured.', 'EMAIL_NOT_CONFIGURED')
        }
        const result = await handlers.sendCredentials(
          { distributorId: credentialMatch[1] },
          getBearerToken(request),
        )
        sendJson(response, 200, result, origin)
        return
      }

      sendJson(response, 404, { success: false, message: 'Endpoint not found.' }, origin)
    } catch (caught) {
      const error = safeEmailError(caught)
      if (!(caught instanceof AppError)) {
        logger.error('DMS auth request failed:', caught?.name || 'UnknownError')
      }
      if (error.code === 'EMAIL_DELIVERY_FAILED') {
        logger.warn('DMS credential email delivery failed.')
      }
      sendJson(response, error.status || 500, {
        success: false,
        message: error.message,
        code: error.code,
      }, origin)
    }
  })

  server.on('clientError', (_error, socket) => {
    socket.end('HTTP/1.1 400 Bad Request\r\n\r\n')
  })
  return server
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const server = await createDmsServer()
  const port = Number(serverEnv.PORT || 8787)
  server.listen(port, '0.0.0.0', () => {
    console.info(`DMS auth API listening on port ${port}`)
  })
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => server.close(() => process.exit(0)))
  }
}
