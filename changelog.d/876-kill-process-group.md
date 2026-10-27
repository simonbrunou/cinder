### Fixed
- **A stopped `unrar`, `ffprobe` or `ffmpeg` call also stops what it started (#876).** When an
  external tool ran past its time limit, or a RAR extraction went past its size ceiling, Cinder
  killed only the tool's own process. A wrapper script that ran the real tool as a child kept that
  child running, so an extraction could keep filling the disk after Cinder had given up on it.
  Cinder now kills every process the tool started along with it. A process that moves itself out
  of the tool's process group (`setsid`, `setpgid`) is still out of reach.
