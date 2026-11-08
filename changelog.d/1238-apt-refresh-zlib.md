### Security
- **Debian `zlib1g` 1:1.3.dfsg+really1.3.1-1+b1 → 1:1.3.dfsg+really1.3.1-1+deb13u1 in the
  container image (CVE-2026-76844, CVE-2026-85091).** Debian trixie-security fixed two HIGH
  advisories in `zlib1g` after the runtime layer was last rebuilt, and Trivy failed `container`
  on every PR. `APT_REFRESH` is bumped so the layer's `apt-get upgrade` runs again.
