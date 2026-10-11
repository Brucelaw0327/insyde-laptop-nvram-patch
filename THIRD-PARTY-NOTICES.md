# Third-party components

This repository ships two third-party binaries. Both are unmodified official
builds; the hashes below are the ones shipped here.

## 7-Zip (`bin/7za.exe`)

- Version 26.04, standalone console build from the official
  [`ip7z/7zip`](https://github.com/ip7z/7zip) release (`7z2604-extra.7z`,
  sha256 of that package: `dc4b11d3...`, identical on 7-zip.org).
- License: LGPL-3.0 (with unRAR restriction). See `bin/7za-LICENSE.txt`.
- Source: https://www.7-zip.org/ / https://github.com/ip7z/7zip

## Python (`tools/runtime/python/`)

- Embeddable CPython 3.13.16 (amd64), unmodified, from
  https://www.python.org/ftp/python/3.13.16/python-3.13.16-embed-amd64.zip
  (zip sha256: `97dae5274cc54867065e8d5a3226e48c35017ed332a0fdb0e27d5b5821961297`).
- License: Python Software Foundation License. See
  `tools/runtime/python/LICENSE.txt`.

## Not included on purpose

- **H2OUVE** and its kernel driver (Insyde Software proprietary) are NOT part
  of this repository -- see `h2ouve/README.md`.
- **No firmware images.** The Setup-module extraction lives in `bios_cache/`
  (git-ignored) and is produced locally from YOUR vendor update package.
