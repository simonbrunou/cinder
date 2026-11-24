### Fixed
- **A download that qBittorrent, Transmission or NZBGet holds on purpose no longer counts as stalled
  or failed while it waits, unless NZBGet does not report a paused job's health and critical health
  as whole numbers, with the health at or above critical, or Transmission reports a local error
  (#1602).** These now show as "Paused by download client", as a job in a paused SABnzbd queue does:
  a torrent stopped or queued before completion in qBittorrent, a torrent stopped before completion
  or waiting in Transmission's download queue, an NZBGet job queued to download while NZBGet's
  downloads are paused, and an NZBGet job paused at or above its critical health. Once Cinder sees
  the hold, the time held no longer counts toward the no-progress limit (24 hours by default). Once
  the client runs the download again, its window for a torrent with no speed starts over: 30 minutes
  with no connected seeds and 2 hours with some, by default. Before, with the stall reaper on (the
  default), Cinder removed and blocklisted such a qBittorrent torrent or queued Transmission torrent
  once that window passed, and such an NZBGet job queued while downloads are paused once the 24-hour
  limit passed. It also treated a Transmission torrent stopped before completion and a paused NZBGet
  job as failed downloads. An NZBGet job of force priority queued to download still counts toward
  the limit while NZBGet's downloads are paused, since NZBGet keeps downloading it. An NZBGet job
  paused below its critical health, as NZBGet's health check pauses a release missing too many
  articles, still fails. So does a paused NZBGet job whose health or critical health NZBGet does not
  report as a whole number, and a Transmission torrent with a local error.
