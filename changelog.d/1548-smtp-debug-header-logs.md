### Security
- **At the debug log level, the server log no longer quotes the recipient's address of a mail
  Cinder sends through SMTP (#1548).** The default `info` level never printed these lines. An
  operator who lowered the level to `debug`, for example with `Logger.configure/1` in a remote
  shell, got several `Headers: [...]` lines per mail from the SMTP library's `mimemail` module.
  Each line that listed the mail's own headers held the To address, whether or not the mail went
  out. Cinder now sets that module's log level to `info` at boot, so its lines stay out of the log
  at every level. Cinder's own debug lines still print.
