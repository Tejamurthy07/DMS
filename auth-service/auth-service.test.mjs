import assert from 'node:assert/strict'
import test from 'node:test'
import { createAuthHandlers, hashOpaqueToken } from './auth-service.mjs'
import { hashPassword, verifyPassword } from './passwords.mjs'

const distributorId = '001000000000001AAA'
const distributor = {
  id: distributorId,
  name: 'Northwind Distribution',
  email: 'northwind@example.com',
  category: 'Distributor',
  active: 'Yes',
  loginStatus: 'Active',
}

class MemoryRepository {
  constructor() {
    this.distributors = new Map([[distributorId, { ...distributor }]])
    this.records = new Map()
    this.nextId = 1
  }

  async findAuthByUsername(username) {
    return [...this.records.values()].find((record) => record.username === username) || null
  }

  async findAuthBySessionHash(hash) {
    return [...this.records.values()].find((record) => record.sessionTokenHash === hash) || null
  }

  async findAuthByResetHash(hash) {
    return [...this.records.values()].find((record) => record.resetTokenHash === hash) || null
  }

  async findDistributor(id) {
    return this.distributors.get(id) || null
  }

  async searchDistributors(search) {
    return [...this.distributors.values()]
      .filter((record) => record.name.includes(search) || record.email.includes(search))
      .map(({ id, name, email }) => ({ id, name, email }))
  }

  async upsertAuth(record) {
    const existing = this.records.get(record.id)
      || await this.findAuthByUsername(record.username)
    const saved = { ...existing, ...record, id: existing?.id || `auth-${this.nextId++}` }
    this.records.set(saved.id, saved)
    return saved
  }

  async updateAuth(id, patch) {
    const record = this.records.get(id)
    if (!record) throw new Error('Missing test auth record')
    Object.assign(record, patch)
    return record
  }
}

async function createFixture(options = {}) {
  const repository = new MemoryRepository()
  repository.dummyPasswordHash = await hashPassword('unavailable-dummy-password')
  const messages = []
  let timestamp = Date.now()
  const handlers = createAuthHandlers({
    repository,
    sendEmail: async (message) => {
      if (options.failEmail) {
        const error = new Error('Email provider failure')
        error.status = 502
        error.code = 'EMAIL_DELIVERY_FAILED'
        throw error
      }
      messages.push(message)
    },
    authorizeAdmin: async (token) => {
      if (token !== 'authorized-admin') {
        const error = new Error('Admin required')
        error.status = 403
        error.code = 'ADMIN_UNAUTHORIZED'
        throw error
      }
    },
    loginUrl: 'https://dms.example.com/login',
    now: () => timestamp,
  })
  return {
    repository,
    messages,
    handlers,
    setTime(value) { timestamp = value },
    setEmailFailure(value) { options.failEmail = value },
  }
}

test('credential issue uses distributor email, stores only a scrypt hash, and requires first-login change', async () => {
  const fixture = await createFixture()
  const result = await fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin')
  const record = await fixture.repository.findAuthByUsername(distributor.email)
  const passwordMatch = fixture.messages[0].text.match(/Temporary password: (.+)/)
  const temporaryPassword = passwordMatch?.[1]

  assert.equal(result.success, true)
  assert.equal(record.username, distributor.email)
  assert.equal(record.mustChangePassword, true)
  assert.match(record.passwordHash, /^scrypt\$16384\$8\$1\$/)
  assert.ok(temporaryPassword)
  assert.ok(await verifyPassword(temporaryPassword, record.passwordHash))
  assert.ok(fixture.messages[0].text.includes(`Username: ${distributor.email}`))
  assert.ok(fixture.messages[0].text.includes('You must create a new password'))
  assert.ok(!JSON.stringify(record).includes(temporaryPassword))
})

test('temporary login is confined to password change; permanent login replaces temporary credentials', async () => {
  const fixture = await createFixture()
  await fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin')
  const tempPassword = fixture.messages[0].text.match(/Temporary password: (.+)/)[1]
  const firstLogin = await fixture.handlers.login({ email: distributor.email, password: tempPassword })

  assert.equal(firstLogin.user.mustChangePassword, true)
  await assert.rejects(
    fixture.handlers.getSession(firstLogin.accessToken),
    (error) => error.code === 'PASSWORD_CHANGE_REQUIRED',
  )
  await assert.rejects(
    fixture.handlers.changePassword({
      currentPassword: tempPassword,
      newPassword: 'DmsPermanent123!',
      confirmNewPassword: 'Mismatch123!',
    }, firstLogin.accessToken),
    /do not match/,
  )

  const changed = await fixture.handlers.changePassword({
    currentPassword: tempPassword,
    newPassword: 'DmsPermanent123!',
    confirmNewPassword: 'DmsPermanent123!',
  }, firstLogin.accessToken)
  assert.equal(changed.user.mustChangePassword, false)
  assert.equal((await fixture.handlers.getSession(changed.accessToken)).user.email, distributor.email)
  await assert.rejects(
    fixture.handlers.login({ email: distributor.email, password: tempPassword }),
    (error) => error.code === 'INVALID_CREDENTIALS',
  )
  const normalLogin = await fixture.handlers.login({
    email: distributor.email,
    password: 'DmsPermanent123!',
  })
  assert.equal(normalLogin.user.mustChangePassword, false)
})

test('credential reset invalidates prior credentials and duplicate sends do not create duplicate accounts', async () => {
  const fixture = await createFixture()
  await fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin')
  const first = await fixture.repository.findAuthByUsername(distributor.email)
  const firstId = first.id
  const firstPassword = fixture.messages[0].text.match(/Temporary password: (.+)/)[1]

  await fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin')
  const second = await fixture.repository.findAuthByUsername(distributor.email)
  const secondPassword = fixture.messages[1].text.match(/Temporary password: (.+)/)[1]
  assert.equal(second.id, firstId)
  assert.equal(fixture.repository.records.size, 1)
  await assert.rejects(
    fixture.handlers.login({ email: distributor.email, password: firstPassword }),
    (error) => error.code === 'INVALID_CREDENTIALS',
  )
  assert.equal((await fixture.handlers.login({ email: distributor.email, password: secondPassword })).user.mustChangePassword, true)
})

test('inactive distributors and unauthorized admins cannot authenticate or issue credentials', async () => {
  const fixture = await createFixture()
  await assert.rejects(
    fixture.handlers.sendCredentials({ distributorId }, 'untrusted'),
    (error) => error.code === 'ADMIN_UNAUTHORIZED',
  )
  assert.equal(fixture.repository.records.size, 0)

  await fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin')
  const temporaryPassword = fixture.messages[0].text.match(/Temporary password: (.+)/)[1]
  fixture.repository.distributors.get(distributorId).active = 'No'
  await assert.rejects(
    fixture.handlers.login({ email: distributor.email, password: temporaryPassword }),
    (error) => error.code === 'INVALID_CREDENTIALS',
  )
})

test('password recovery uses a hashed, expiring, single-use token and clears active sessions', async () => {
  const fixture = await createFixture()
  await fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin')
  const temporaryPassword = fixture.messages[0].text.match(/Temporary password: (.+)/)[1]
  const login = await fixture.handlers.login({ email: distributor.email, password: temporaryPassword })
  await fixture.handlers.changePassword({
    currentPassword: temporaryPassword,
    newPassword: 'OldPermanent123!',
    confirmNewPassword: 'OldPermanent123!',
  }, login.accessToken)
  const activeSession = await fixture.handlers.login({
    email: distributor.email,
    password: 'OldPermanent123!',
  })

  const generic = await fixture.handlers.forgotPassword({ email: 'missing@example.com' })
  assert.equal(generic.message, (await fixture.handlers.forgotPassword({ email: distributor.email })).message)
  const email = fixture.messages.at(-1)
  const resetUrl = new URL(email.text.match(/https:\/\/\S+/)[0])
  const rawToken = resetUrl.searchParams.get('token')
  const record = await fixture.repository.findAuthByUsername(distributor.email)
  assert.equal(record.resetTokenHash, hashOpaqueToken(rawToken))
  assert.notEqual(record.resetTokenHash, rawToken)

  await fixture.handlers.resetPassword({
    token: rawToken,
    password: 'NewPermanent456!',
    confirmPassword: 'NewPermanent456!',
  })
  await assert.rejects(
    fixture.handlers.getSession(activeSession.accessToken),
    (error) => error.code === 'SESSION_EXPIRED',
  )
  assert.equal((await fixture.handlers.login({
    email: distributor.email,
    password: 'NewPermanent456!',
  })).user.mustChangePassword, false)
  await assert.rejects(
    fixture.handlers.resetPassword({
      token: rawToken,
      password: 'AnotherPassword789!',
      confirmPassword: 'AnotherPassword789!',
    }),
    /invalid or has expired/,
  )
  assert.equal(generic.success, true)
})

test('email failure is surfaced and no success response is returned', async () => {
  const fixture = await createFixture({ failEmail: true })
  await assert.rejects(
    fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin'),
    (error) => error.code === 'EMAIL_DELIVERY_FAILED',
  )
  assert.equal(fixture.messages.length, 0)
  assert.equal(await fixture.repository.findAuthByUsername(distributor.email), null)
})

test('failed credential email does not replace working credentials', async () => {
  const fixture = await createFixture()
  await fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin')
  const oldPassword = fixture.messages[0].text.match(/Temporary password: (.+)/)[1]
  const oldRecord = await fixture.repository.findAuthByUsername(distributor.email)

  fixture.setEmailFailure(true)
  await assert.rejects(
    fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin'),
    (error) => error.code === 'EMAIL_DELIVERY_FAILED',
  )

  const currentRecord = await fixture.repository.findAuthByUsername(distributor.email)
  assert.equal(currentRecord.passwordHash, oldRecord.passwordHash)
  assert.equal(currentRecord.credentialIssuedAt, oldRecord.credentialIssuedAt)
  assert.equal(
    (await fixture.handlers.login({ email: distributor.email, password: oldPassword })).user.mustChangePassword,
    true,
  )
})

test('logout revokes the opaque session token', async () => {
  const fixture = await createFixture()
  await fixture.handlers.sendCredentials({ distributorId }, 'authorized-admin')
  const temporaryPassword = fixture.messages[0].text.match(/Temporary password: (.+)/)[1]
  const login = await fixture.handlers.login({ email: distributor.email, password: temporaryPassword })
  await fixture.handlers.logout(login.accessToken)
  await assert.rejects(
    fixture.handlers.changePassword({
      currentPassword: temporaryPassword,
      newPassword: 'DmsPermanent123!',
      confirmNewPassword: 'DmsPermanent123!',
    }, login.accessToken),
    (error) => error.code === 'SESSION_EXPIRED',
  )
})
