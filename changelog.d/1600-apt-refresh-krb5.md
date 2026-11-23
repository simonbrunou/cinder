### Security
- **Debian's krb5 libraries `1.21.3-5+deb13u1` → `1.21.3-5+deb13u2` in the container image
  (CVE-2026-71199, CVE-2026-71200, CVE-2026-107364, CVE-2026-112315 to CVE-2026-112323,
  CVE-2026-118380, CVE-2026-119079).** Trivy failed `container` on these 14 HIGH advisories in
  `libgssapi-krb5-2`, `libk5crypto3`, `libkrb5-3` and `libkrb5support0`, because an image built
  from the cached runtime layer held the older packages. Debian trixie-security ships the fixed
  version. `APT_REFRESH` is bumped so the layer's `apt-get upgrade` runs again.
