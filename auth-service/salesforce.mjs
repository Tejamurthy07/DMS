import { readFile } from 'node:fs/promises'
import { createSign } from 'node:crypto'
import { AppError, normalizeEmail } from './auth-service.mjs'

const AUTH_OBJECT = 'DMS_Distributor_Auth__c'
const AUTH_FIELDS = [
  'Id',
  'Username__c',
  'Distributor__c',
  'Password_Hash__c',
  'Must_Change_Password__c',
  'Session_Token_Hash__c',
  'Session_Expires_At__c',
  'Reset_Token_Hash__c',
  'Reset_Token_Expires_At__c',
]

function encodeBase64Url(value) {
  return Buffer.from(value).toString('base64url')
}

function escapeSoql(value) {
  return value.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/%/g, '\\%').replace(/_/g, '\\_')
}

function mapAuth(record) {
  if (!record) {
    return null
  }
  return {
    id: record.Id,
    username: record.Username__c,
    distributorId: record.Distributor__c,
    passwordHash: record.Password_Hash__c,
    mustChangePassword: record.Must_Change_Password__c,
    sessionTokenHash: record.Session_Token_Hash__c,
    sessionExpiresAt: record.Session_Expires_At__c,
    resetTokenHash: record.Reset_Token_Hash__c,
    resetTokenExpiresAt: record.Reset_Token_Expires_At__c,
  }
}

function mapDistributor(account) {
  if (!account) {
    return null
  }
  return {
    id: account.Id,
    name: account.Name,
    email: account.Email__c,
    category: account.Account_Category__c,
    active: account.Active__c,
    loginStatus: account.Login_Status__c,
  }
}

export class SalesforceClient {
  constructor(env = process.env) {
    this.env = env
    this.apiVersion = env.SF_API_VERSION || '60.0'
    this.authBaseUrl = (env.SF_AUTH_BASE_URL || '').replace(/\/+$/, '')
    this.accessToken = null
    this.instanceUrl = null
    this.tokenExpiresAt = 0
    this.tokenRequest = null
    this.privateKeyRequest = null
    this.allowedAdminIds = new Set(
      (env.SF_ADMIN_ALLOWED_USER_IDS || '')
        .split(',')
        .map((id) => id.trim().toLowerCase())
        .filter(Boolean),
    )
  }

  async getPrivateKey() {
    if (!this.privateKeyRequest) {
      this.privateKeyRequest = this.env.SF_PRIVATE_KEY_PATH
        ? readFile(this.env.SF_PRIVATE_KEY_PATH, 'utf8')
        : Promise.resolve(this.env.SF_PRIVATE_KEY?.replace(/\\n/g, '\n'))
    }
    const key = await this.privateKeyRequest
    if (!key) {
      throw new AppError(503, 'Salesforce authentication is not configured.', 'SF_NOT_CONFIGURED')
    }
    return key
  }

  async getIntegrationToken() {
    if (this.accessToken && Date.now() < this.tokenExpiresAt - 60_000) {
      return this.accessToken
    }
    if (this.tokenRequest) {
      return this.tokenRequest
    }

    this.tokenRequest = this.requestIntegrationToken()
    try {
      return await this.tokenRequest
    } finally {
      this.tokenRequest = null
    }
  }

  async requestIntegrationToken() {
    if (!this.authBaseUrl || !this.env.SF_CLIENT_ID || !this.env.SF_USERNAME) {
      throw new AppError(503, 'Salesforce integration is not configured.', 'SF_NOT_CONFIGURED')
    }

    const issuedAt = Math.floor(Date.now() / 1000)
    const header = encodeBase64Url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
    const claim = encodeBase64Url(JSON.stringify({
      iss: this.env.SF_CLIENT_ID,
      sub: this.env.SF_USERNAME,
      aud: this.authBaseUrl,
      exp: issuedAt + 180,
    }))
    const unsigned = `${header}.${claim}`
    const signer = createSign('RSA-SHA256')
    signer.update(unsigned)
    const assertion = `${unsigned}.${signer.sign(await this.getPrivateKey()).toString('base64url')}`

    let response
    try {
      response = await fetch(`${this.authBaseUrl}/services/oauth2/token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
        body: new URLSearchParams({
          grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          assertion,
        }),
      })
    } catch {
      throw new AppError(502, 'Salesforce integration is temporarily unavailable.', 'SF_UNAVAILABLE')
    }

    const payload = await response.json().catch(() => ({}))
    if (!response.ok || !payload.access_token || !payload.instance_url) {
      throw new AppError(502, 'Salesforce integration could not authenticate.', 'SF_AUTH_FAILED')
    }

    const instanceUrl = new URL(payload.instance_url)
    if (instanceUrl.protocol !== 'https:') {
      throw new AppError(502, 'Salesforce returned an invalid API address.', 'SF_INVALID_URL')
    }

    this.accessToken = payload.access_token
    this.instanceUrl = instanceUrl.origin
    this.tokenExpiresAt = Date.now() + 10 * 60 * 1000
    return this.accessToken
  }

  async request(path, options = {}) {
    const token = await this.getIntegrationToken()
    let response
    try {
      response = await fetch(`${this.instanceUrl}/services/data/v${this.apiVersion}/${path}`, {
        ...options,
        headers: {
          Accept: 'application/json',
          Authorization: `Bearer ${token}`,
          ...(options.body ? { 'Content-Type': 'application/json' } : {}),
          ...options.headers,
        },
      })
    } catch {
      throw new AppError(502, 'Salesforce integration is temporarily unavailable.', 'SF_UNAVAILABLE')
    }

    if (response.status === 204) {
      return null
    }
    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      if (response.status === 404) {
        throw new AppError(404, 'The requested Salesforce record was not found.', 'SF_RECORD_NOT_FOUND')
      }
      throw new AppError(502, 'Salesforce could not complete the data operation.', 'SF_REQUEST_FAILED')
    }
    return payload
  }

  async query(soql) {
    const payload = await this.request(`query/?${new URLSearchParams({ q: soql })}`)
    return payload.records || []
  }

  async findAuthByUsername(username) {
    const safe = escapeSoql(normalizeEmail(username))
    const records = await this.query(
      `SELECT ${AUTH_FIELDS.join(',')} FROM ${AUTH_OBJECT} WHERE Username__c = '${safe}' LIMIT 1`,
    )
    return mapAuth(records[0])
  }

  async findAuthBySessionHash(hash) {
    const records = await this.query(
      `SELECT ${AUTH_FIELDS.join(',')} FROM ${AUTH_OBJECT} WHERE Session_Token_Hash__c = '${escapeSoql(hash)}' LIMIT 1`,
    )
    return mapAuth(records[0])
  }

  async findAuthByResetHash(hash) {
    const records = await this.query(
      `SELECT ${AUTH_FIELDS.join(',')} FROM ${AUTH_OBJECT} WHERE Reset_Token_Hash__c = '${escapeSoql(hash)}' LIMIT 1`,
    )
    return mapAuth(records[0])
  }

  async findDistributor(id) {
    const record = await this.request(
      `sobjects/Account/${encodeURIComponent(id)}?fields=Id,Name,Email__c,Account_Category__c,Active__c,Login_Status__c`,
    )
    return mapDistributor(record)
  }

  async searchDistributors(search) {
    const safe = escapeSoql(search)
    const records = await this.query(
      `SELECT Id,Name,Email__c,Account_Category__c,Active__c,Login_Status__c FROM Account WHERE Account_Category__c = 'Distributor' AND Active__c = 'Yes' AND Login_Status__c = 'Active' AND Email__c != null AND (Name LIKE '%${safe}%' OR Email__c LIKE '%${safe}%') ORDER BY Name LIMIT 50`,
    )
    return records.map(mapDistributor).map((record) => ({
      id: record.id,
      name: record.name,
      email: record.email,
    }))
  }

  async upsertAuth(record) {
    const fields = {
      Username__c: record.username,
      Distributor__c: record.distributorId,
      Password_Hash__c: record.passwordHash,
      Must_Change_Password__c: record.mustChangePassword,
      Session_Token_Hash__c: record.sessionTokenHash,
      Session_Expires_At__c: record.sessionExpiresAt,
      Reset_Token_Hash__c: record.resetTokenHash,
      Reset_Token_Expires_At__c: record.resetTokenExpiresAt,
      Credential_Issued_At__c: record.credentialIssuedAt,
    }
    await this.request(
      `sobjects/${AUTH_OBJECT}/Username__c/${encodeURIComponent(record.username)}`,
      {
        method: 'PATCH',
        body: JSON.stringify(fields),
      },
    )
  }

  async updateAuth(id, patch) {
    const fields = {}
    const mapping = {
      passwordHash: 'Password_Hash__c',
      mustChangePassword: 'Must_Change_Password__c',
      sessionTokenHash: 'Session_Token_Hash__c',
      sessionExpiresAt: 'Session_Expires_At__c',
      resetTokenHash: 'Reset_Token_Hash__c',
      resetTokenExpiresAt: 'Reset_Token_Expires_At__c',
    }
    for (const [key, field] of Object.entries(mapping)) {
      if (Object.hasOwn(patch, key)) {
        fields[field] = patch[key]
      }
    }
    await this.request(`sobjects/${AUTH_OBJECT}/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      body: JSON.stringify(fields),
    })
  }

  async authorizeAdmin(accessToken) {
    if (!accessToken || this.allowedAdminIds.size === 0 || !this.authBaseUrl) {
      throw new AppError(403, 'An authorized administrator session is required.', 'ADMIN_UNAUTHORIZED')
    }

    let response
    try {
      response = await fetch(`${this.authBaseUrl}/services/oauth2/userinfo`, {
        headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' },
      })
    } catch {
      throw new AppError(502, 'Administrator identity could not be verified.', 'ADMIN_IDENTITY_UNAVAILABLE')
    }
    if (!response.ok) {
      throw new AppError(401, 'Administrator session is invalid or expired.', 'ADMIN_SESSION_INVALID')
    }
    const identity = await response.json().catch(() => ({}))
    const userId = String(identity.user_id || '').toLowerCase()
    if (!identity.active || !userId || !this.allowedAdminIds.has(userId)) {
      throw new AppError(403, 'An authorized administrator session is required.', 'ADMIN_UNAUTHORIZED')
    }
  }
}

export function createSalesforceRepository(client) {
  return {
    findAuthByUsername: (username) => client.findAuthByUsername(username),
    findAuthBySessionHash: (hash) => client.findAuthBySessionHash(hash),
    findAuthByResetHash: (hash) => client.findAuthByResetHash(hash),
    findDistributor: (id) => client.findDistributor(id),
    searchDistributors: (search) => client.searchDistributors(search),
    upsertAuth: (record) => client.upsertAuth(record),
    updateAuth: (id, patch) => client.updateAuth(id, patch),
  }
}
