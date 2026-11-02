import { createHash, randomBytes } from 'node:crypto'
import {
  createTemporaryPassword,
  hashPassword,
  isPasswordPolicySatisfied,
  verifyPassword,
} from './passwords.mjs'

export const SESSION_TTL_MS = 8 * 60 * 60 * 1000
export const RESET_TOKEN_TTL_MS = 30 * 60 * 1000
const GENERIC_LOGIN_ERROR = 'Email or password is incorrect.'
const GENERIC_RESET_MESSAGE = 'If the email is registered, password reset instructions will be sent.'

export class AppError extends Error {
  constructor(status, message, code = 'REQUEST_FAILED') {
    super(message)
    this.status = status
    this.code = code
  }
}

export function hashOpaqueToken(token) {
  return createHash('sha256').update(token).digest('hex')
}

export function normalizeEmail(email) {
  return typeof email === 'string' ? email.trim().toLowerCase() : ''
}

export function isEligibleDistributor(distributor, email = distributor?.email) {
  return Boolean(distributor
    && distributor.category === 'Distributor'
    && distributor.active === 'Yes'
    && distributor.loginStatus === 'Active'
    && typeof distributor.email === 'string'
    && normalizeEmail(distributor.email) === normalizeEmail(email))
}

export function createAuthHandlers({
  repository,
  sendEmail,
  authorizeAdmin,
  warnEmailFailure = () => {},
  loginUrl,
  sessionTtlMs = SESSION_TTL_MS,
  resetTtlMs = RESET_TOKEN_TTL_MS,
  now = () => Date.now(),
}) {
  async function findValidSession(token, { allowFirstLogin = false } = {}) {
    if (typeof token !== 'string' || token.length < 32) {
      throw new AppError(401, 'Sign in to continue.', 'UNAUTHORIZED')
    }

    const record = await repository.findAuthBySessionHash(hashOpaqueToken(token))
    const sessionExpiry = Date.parse(record?.sessionExpiresAt || '')
    if (!record || !Number.isFinite(sessionExpiry) || sessionExpiry <= now()) {
      throw new AppError(401, 'Your session has expired. Sign in again.', 'SESSION_EXPIRED')
    }

    const distributor = await repository.findDistributor(record.distributorId)
    if (!isEligibleDistributor(distributor, record.username)) {
      throw new AppError(401, 'This distributor account is inactive.', 'ACCOUNT_INACTIVE')
    }
    if (record.mustChangePassword && !allowFirstLogin) {
      throw new AppError(403, 'Change your temporary password before continuing.', 'PASSWORD_CHANGE_REQUIRED')
    }

    return { record, distributor }
  }

  async function login(input) {
    const email = normalizeEmail(input?.email)
    const password = typeof input?.password === 'string' ? input.password : ''
    if (!email || email.length > 254 || !password || password.length > 128) {
      throw new AppError(400, 'Enter your email address and password.')
    }

    const record = await repository.findAuthByUsername(email)
    const validAccount = record
      ? isEligibleDistributor(await repository.findDistributor(record.distributorId), email)
      : false
    const passwordMatches = await verifyPassword(
      password,
      record?.passwordHash ?? repository.dummyPasswordHash,
    )

    if (!record || !validAccount || !passwordMatches) {
      throw new AppError(401, GENERIC_LOGIN_ERROR, 'INVALID_CREDENTIALS')
    }

    const accessToken = randomBytes(32).toString('base64url')
    const sessionExpiresAt = new Date(now() + sessionTtlMs).toISOString()
    await repository.updateAuth(record.id, {
      sessionTokenHash: hashOpaqueToken(accessToken),
      sessionExpiresAt,
      resetTokenHash: null,
      resetTokenExpiresAt: null,
    })

    const distributor = await repository.findDistributor(record.distributorId)
    return {
      accessToken,
      expiresAt: sessionExpiresAt,
      user: {
        id: distributor.id,
        name: distributor.name,
        email: record.username,
        mustChangePassword: record.mustChangePassword,
      },
    }
  }

  async function sendCredentials(input, adminToken) {
    await authorizeAdmin(adminToken)
    const distributorId = typeof input?.distributorId === 'string' ? input.distributorId.trim() : ''
    if (!/^[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?$/.test(distributorId)) {
      throw new AppError(400, 'Select a valid distributor record.')
    }

    const distributor = await repository.findDistributor(distributorId)
    if (!isEligibleDistributor(distributor)) {
      throw new AppError(400, 'The selected record is not an active distributor with a registered email.')
    }

    const username = normalizeEmail(distributor.email)
    const existing = await repository.findAuthByUsername(username)
    if (existing && existing.distributorId !== distributor.id) {
      throw new AppError(409, 'This email is already associated with another distributor.')
    }

    const temporaryPassword = createTemporaryPassword()
    const passwordHash = await hashPassword(temporaryPassword)
    const authRecord = {
      ...(existing ? { id: existing.id } : {}),
      username,
      distributorId: distributor.id,
      passwordHash,
      mustChangePassword: true,
      sessionTokenHash: null,
      sessionExpiresAt: null,
      resetTokenHash: null,
      resetTokenExpiresAt: null,
      credentialIssuedAt: new Date(now()).toISOString(),
    }

    await sendEmail({
      to: username,
      subject: 'Your DMS Login Credentials',
      text: [
        `Hello ${distributor.name},`,
        '',
        `Username: ${username}`,
        `Temporary password: ${temporaryPassword}`,
        `DMS login: ${loginUrl}`,
        '',
        'Sign in with the temporary password. You must create a new password before accessing your dashboard.',
        'Do not share these credentials with anyone.',
      ].join('\n'),
      html: [
        `<p>Hello ${escapeHtml(distributor.name)},</p>`,
        `<p><strong>Username:</strong> ${escapeHtml(username)}<br>`,
        `<strong>Temporary password:</strong> ${escapeHtml(temporaryPassword)}</p>`,
        `<p><a href="${escapeHtml(loginUrl)}">Open the DMS login page</a></p>`,
        '<p>Sign in with the temporary password. You must create a new password before accessing your dashboard.</p>',
        '<p><strong>Security notice:</strong> Do not share these credentials with anyone.</p>',
      ].join(''),
    })
    await repository.upsertAuth(authRecord)

    return { success: true, message: 'Credentials were emailed to the distributor.' }
  }

  async function changePassword(input, sessionToken) {
    const { record } = await findValidSession(sessionToken, { allowFirstLogin: true })
    const currentPassword = typeof input?.currentPassword === 'string' ? input.currentPassword : ''
    const newPassword = typeof input?.newPassword === 'string' ? input.newPassword : ''
    const confirmNewPassword = typeof input?.confirmNewPassword === 'string'
      ? input.confirmNewPassword
      : ''

    if (!currentPassword || !newPassword || !confirmNewPassword) {
      throw new AppError(400, 'All password fields are required.')
    }
    if (newPassword !== confirmNewPassword) {
      throw new AppError(400, 'The new password and confirmation do not match.')
    }
    if (!isPasswordPolicySatisfied(newPassword)) {
      throw new AppError(400, 'Use 12–128 characters with uppercase, lowercase, a number, and a symbol.')
    }
    if (currentPassword === newPassword) {
      throw new AppError(400, 'Choose a new password different from the current password.')
    }
    if (!await verifyPassword(currentPassword, record.passwordHash)) {
      throw new AppError(401, 'The current password is incorrect.', 'INVALID_CURRENT_PASSWORD')
    }

    const accessToken = randomBytes(32).toString('base64url')
    const sessionExpiresAt = new Date(now() + sessionTtlMs).toISOString()
    await repository.updateAuth(record.id, {
      passwordHash: await hashPassword(newPassword),
      mustChangePassword: false,
      sessionTokenHash: hashOpaqueToken(accessToken),
      sessionExpiresAt,
      resetTokenHash: null,
      resetTokenExpiresAt: null,
    })

    const distributor = await repository.findDistributor(record.distributorId)
    return {
      accessToken,
      expiresAt: sessionExpiresAt,
      user: {
        id: distributor.id,
        name: distributor.name,
        email: record.username,
        mustChangePassword: false,
      },
    }
  }

  async function getSession(sessionToken) {
    const { record, distributor } = await findValidSession(sessionToken)
    return {
      user: {
        id: distributor.id,
        name: distributor.name,
        email: record.username,
        mustChangePassword: false,
      },
    }
  }

  async function logout(sessionToken) {
    if (typeof sessionToken !== 'string' || sessionToken.length < 32) {
      return { success: true }
    }
    const record = await repository.findAuthBySessionHash(hashOpaqueToken(sessionToken))
    if (record) {
      await repository.updateAuth(record.id, {
        sessionTokenHash: null,
        sessionExpiresAt: null,
      })
    }
    return { success: true }
  }

  async function forgotPassword(input) {
    const email = normalizeEmail(input?.email)
    if (!email || email.length > 254) {
      throw new AppError(400, 'Enter a valid email address.')
    }

    const record = await repository.findAuthByUsername(email)
    if (record) {
      const distributor = await repository.findDistributor(record.distributorId)
      if (isEligibleDistributor(distributor, email)) {
        const resetToken = randomBytes(32).toString('base64url')
        await repository.updateAuth(record.id, {
          resetTokenHash: hashOpaqueToken(resetToken),
          resetTokenExpiresAt: new Date(now() + resetTtlMs).toISOString(),
        })
        const resetUrl = new URL('/reset-password', loginUrl)
        resetUrl.searchParams.set('token', resetToken)
        try {
          await sendEmail({
            to: email,
            subject: 'Reset your DMS password',
            text: `Use this single-use link to reset your DMS password within 30 minutes: ${resetUrl}`,
            html: `<p>Use this single-use link to reset your DMS password within 30 minutes:</p><p><a href="${escapeHtml(resetUrl.toString())}">Reset password</a></p>`,
          })
        } catch (error) {
          await repository.updateAuth(record.id, {
            resetTokenHash: null,
            resetTokenExpiresAt: null,
          })
          warnEmailFailure(error?.code || 'EMAIL_DELIVERY_FAILED')
        }
      }
    }

    return { success: true, message: GENERIC_RESET_MESSAGE }
  }

  async function resetPassword(input) {
    const token = typeof input?.token === 'string' ? input.token : ''
    const password = typeof input?.password === 'string' ? input.password : ''
    const confirmation = typeof input?.confirmPassword === 'string' ? input.confirmPassword : ''
    if (!token || token.length > 256 || !password || !confirmation) {
      throw new AppError(400, 'Complete all password reset fields.')
    }
    if (password !== confirmation) {
      throw new AppError(400, 'The new password and confirmation do not match.')
    }
    if (!isPasswordPolicySatisfied(password)) {
      throw new AppError(400, 'Use 12–128 characters with uppercase, lowercase, a number, and a symbol.')
    }

    const record = await repository.findAuthByResetHash(hashOpaqueToken(token))
    const resetExpiry = Date.parse(record?.resetTokenExpiresAt || '')
    if (!record || !Number.isFinite(resetExpiry) || resetExpiry <= now()) {
      throw new AppError(400, 'This reset link is invalid or has expired.')
    }

    const distributor = await repository.findDistributor(record.distributorId)
    if (!isEligibleDistributor(distributor, record.username)) {
      throw new AppError(400, 'This reset link is invalid or has expired.')
    }

    await repository.updateAuth(record.id, {
      passwordHash: await hashPassword(password),
      mustChangePassword: false,
      sessionTokenHash: null,
      sessionExpiresAt: null,
      resetTokenHash: null,
      resetTokenExpiresAt: null,
    })
    return { success: true, message: 'Password reset. Sign in with your new password.' }
  }

  async function searchDistributors(search, adminToken) {
    await authorizeAdmin(adminToken)
    if (typeof search !== 'string' || search.trim().length < 2) {
      throw new AppError(400, 'Enter at least two characters to search.')
    }
    return repository.searchDistributors(search.trim())
  }

  return {
    login,
    sendCredentials,
    changePassword,
    getSession,
    logout,
    forgotPassword,
    resetPassword,
    searchDistributors,
  }
}

export function createRateLimiter({ limit = 5, windowMs = 15 * 60 * 1000, now = () => Date.now() } = {}) {
  const attempts = new Map()
  return {
    isLimited(key) {
      const current = attempts.get(key)
      if (!current || current.expiresAt <= now()) {
        attempts.delete(key)
        return false
      }
      return current.count >= limit
    },
    fail(key) {
      const current = attempts.get(key)
      if (!current || current.expiresAt <= now()) {
        attempts.set(key, { count: 1, expiresAt: now() + windowMs })
      } else {
        current.count += 1
      }
    },
    succeed(key) {
      attempts.delete(key)
    },
  }
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  })[character])
}
