import {
  randomBytes,
  randomInt,
  scrypt as scryptCallback,
  timingSafeEqual,
} from 'node:crypto'
import { promisify } from 'node:util'

const scrypt = promisify(scryptCallback)
const SCRYPT_OPTIONS = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }
const HASH_BYTES = 64
const UPPER = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
const LOWER = 'abcdefghijkmnopqrstuvwxyz'
const DIGITS = '23456789'
const SYMBOLS = '!@#$%*-_+?'
const PASSWORD_CHARS = UPPER + LOWER + DIGITS + SYMBOLS

export function createTemporaryPassword(length = 24) {
  if (length < 16) {
    throw new RangeError('Temporary passwords must be at least 16 characters.')
  }

  const characters = [
    UPPER[randomInt(UPPER.length)],
    LOWER[randomInt(LOWER.length)],
    DIGITS[randomInt(DIGITS.length)],
    SYMBOLS[randomInt(SYMBOLS.length)],
  ]

  while (characters.length < length) {
    characters.push(PASSWORD_CHARS[randomInt(PASSWORD_CHARS.length)])
  }

  for (let index = characters.length - 1; index > 0; index -= 1) {
    const swapIndex = randomInt(index + 1)
    ;[characters[index], characters[swapIndex]] = [characters[swapIndex], characters[index]]
  }

  return characters.join('')
}

export function isPasswordPolicySatisfied(password) {
  return typeof password === 'string'
    && password.length >= 12
    && password.length <= 128
    && /[a-z]/.test(password)
    && /[A-Z]/.test(password)
    && /\d/.test(password)
    && /[^A-Za-z0-9]/.test(password)
}

export async function hashPassword(password) {
  const salt = randomBytes(16)
  const derivedKey = await scrypt(password, salt, HASH_BYTES, SCRYPT_OPTIONS)
  return [
    'scrypt',
    SCRYPT_OPTIONS.N,
    SCRYPT_OPTIONS.r,
    SCRYPT_OPTIONS.p,
    salt.toString('base64url'),
    derivedKey.toString('base64url'),
  ].join('$')
}

export async function verifyPassword(password, encodedHash) {
  const parts = typeof encodedHash === 'string' ? encodedHash.split('$') : []
  if (parts.length !== 6 || parts[0] !== 'scrypt') {
    return false
  }

  const cost = Number(parts[1])
  const blockSize = Number(parts[2])
  const parallelization = Number(parts[3])
  const salt = Buffer.from(parts[4], 'base64url')
  const expected = Buffer.from(parts[5], 'base64url')

  if (!Number.isSafeInteger(cost) || !Number.isSafeInteger(blockSize)
    || !Number.isSafeInteger(parallelization) || salt.length !== 16
    || expected.length !== HASH_BYTES || cost !== SCRYPT_OPTIONS.N
    || blockSize !== SCRYPT_OPTIONS.r || parallelization !== SCRYPT_OPTIONS.p) {
    return false
  }

  const actual = await scrypt(password, salt, HASH_BYTES, SCRYPT_OPTIONS)
  return timingSafeEqual(actual, expected)
}
