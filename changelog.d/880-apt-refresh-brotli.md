### Security
- **Debian `libbrotli1` 1.1.0-2+b7 → 1.1.0-2+deb13u1 in the container image (CVE-2026-111497).**
  Debian trixie-security fixed a HIGH out-of-bounds write in the Brotli decoder after the runtime
  layer was last rebuilt, and Trivy failed `container` on every PR. `APT_REFRESH` is bumped so
  the layer's `apt-get upgrade` runs again.
