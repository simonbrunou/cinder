### Security
- **Debian's `libzstd1` `1.5.7+dfsg-1` → `1.5.7+dfsg-1+deb13u1` in the container image
  (CVE-2026-124851).** Trivy failed `container` on this HIGH advisory in `libzstd1`, because an
  image built from the cached runtime layer held the older package. Debian trixie-security ships
  the fixed version. `APT_REFRESH` is bumped so the layer's `apt-get upgrade` runs again.
