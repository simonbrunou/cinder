### Security
- **Debian `apt` 3.0.3 → 3.0.4 in the container image (CVE-2026-109518).** Debian
  trixie-security fixed a HIGH advisory in `apt` and `libapt-pkg7.0` after the runtime layer was
  last rebuilt, and Trivy failed `container` on every PR. `APT_REFRESH` is bumped so the layer's
  `apt-get upgrade` runs again.
