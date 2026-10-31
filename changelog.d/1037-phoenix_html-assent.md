### Security
- **`phoenix_html` 4.3.0 → 4.4.0 (CVE-2026-117645).** `attributes_escape/1` did not validate
  attribute names, so an attribute name taken from user input could inject further attributes
  into the rendered HTML. 4.4.0 validates attribute names. The advisory also failed the required
  `mix hex.audit` CI check on every PR.
- **`assent` 0.3.1 → 0.3.2 (CVE-2026-117656).** Assent's Sign in with Apple strategy let the
  unverified `user` callback parameter override the verified ID-token claims, so an attacker
  could sign in as another user. Cinder signs in through Assent's generic OIDC strategy, not the
  Apple one, so it was not exposed. The advisory also failed the required `mix hex.audit` CI
  check on every PR.
