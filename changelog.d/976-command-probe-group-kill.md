### Internal
- When a free-space check times out, Cinder kills the `df` process group, then the `df` itself,
  the same way it stops `unrar`, `ffprobe` and `ffmpeg` (#976). Before, it killed only the `df`,
  so a process the check had started would have kept running. The check starts none today.
