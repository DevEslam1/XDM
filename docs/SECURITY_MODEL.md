# DMX Security Model & Cryptographic Standards

This document describes the backup encryption, build gates, and script isolation models implemented in DMX.

```
┌────────────────────────────────────────────────────────┐
│                   DMX Security Layers                  │
└────────────────────────────────────────────────────────┘
  ├── Cryptographic Backup Storage (XDMCRYPT4)
  │   ├── PBKDF2-HMAC-SHA256 (100,000 iterations)
  │   ├── AES-256-CBC with random 16-byte IV
  │   └── Encrypt-then-MAC (HMAC-SHA256 with constant-time check)
  │
  ├── Build & Release Assurance
  │   └── Release builds enforce cryptographic signing; debug keystore rejected
  │
  └── User Script Sandboxing
      └── Blocks arbitrary runtime eval() and constructor Function() execution
```

## 1. Backup Encryption Standard (XDMCRYPT4)
- **KDF**: PBKDF2 with HMAC-SHA256, 100,000 rounds, 256-bit key derivation using a cryptographically secure 16-byte random salt.
- **Cipher**: AES-256 in CBC mode with a fresh 16-byte IV per backup.
- **Integrity**: HMAC-SHA256 computed across `[magic || salt || iv || ciphertext]`. Constant-time comparison is enforced during decryption to prevent timing attacks.

## 2. Release Signing Enforcement
- Gradle release builds fail with a fatal exception if `keystore.properties` or environment variables are not configured, preventing accidental debug-signed APK distribution.
