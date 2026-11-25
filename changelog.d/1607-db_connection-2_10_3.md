### Security
- **`db_connection` 2.10.1 → 2.10.3 (CVE-2026-133555).** A HIGH advisory against db_connection
  1.1.0 up to 2.10.2. It says that enumerating a forged `DBConnection.Stream` or
  `DBConnection.PrepareStream` struct calls the `{module, function, arguments}` tuple its `:log`
  option holds, and that an attacker who can make an application build and enumerate such a
  struct "can call an exported function of a loaded module with chosen arguments". The advisory
  places the root cause in code that builds structs from untrusted input, not in db_connection
  alone, and db_connection's changelog lists the 2.10.3 fix as hardening that no longer accepts
  such tuples in those structs. The required `mix hex.audit` CI check fails on every PR whose
  `mix.lock` still holds 2.10.1.
