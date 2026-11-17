### Changed
- **The warning about a directory walk whose caller exited now names the reason Cinder's
  monitor on the caller reported (#1361).** The warning "directory walk under ... still runs,
  but its caller exited before reporting it past its deadline" now adds that reason, such as
  `{:shutdown, :closed}` when the caller was the download folders page's scan and the page
  closed. A caller that had already exited when Cinder started to watch it reads `:noproc` there
  instead of its exit reason.
