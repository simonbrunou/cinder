### Security
- **`plug_crypto` 2.2.0 → 2.2.1 (CVE-2026-105963).** A wrong-typed argument to a `Plug.Crypto`
  function raised with the secret key base, a derived key or a compared API key in the stack
  trace, which could land in the logs. 2.2.1 keeps those values out of the error. The advisory
  also failed the required `mix hex.audit` CI check on every PR.
