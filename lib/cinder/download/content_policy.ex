defmodule Cinder.Download.ContentPolicy do
  @moduledoc """
  Decides whether a download's file list marks it as a fake — the payload-bearing torrents that
  advertise a movie and deliver a shortcut, an installer, or a "watch online" script.

  Without this, such a download is only caught by `Cinder.Download.StallReaper`'s absolute
  `max_downloading_timeout` (24h by default), because it never errors and often *completes*: a
  1 MB `.lnk` finishes in seconds and reaches the importer as a release with no usable video.
  Checking the file list catches it in the first tick instead, and the release is blocklisted so
  the next-best candidate is grabbed.

  `check/1` is pure: no DB, no HTTP. `vet/2` is the one impure edge — it fetches the list via
  `Cinder.Download.Client.files/1` and hands it to `check/1`. A client that cannot answer yields
  `:ok`: a check that could not run must never be the thing that kills a download.

  ## ponytail: extension blocklist only

  There is no "the release contains no video file" rule, tempting as it is. Legitimate usenet and
  scene releases ship as `.rar`/`.par2` sets and only become video after unpacking, so that rule
  would delete good downloads — and a false positive here costs real data, which is exactly where
  laziness stops. Extensions that are never part of a media release are unambiguous; that is the
  whole test. Override the list per install with
  `config :cinder, #{inspect(__MODULE__)}, blocked_extensions: ~w(.lnk ...)`.

  **On by default** — the shipped `config/config.exs` sets `enabled: true`. (`enabled?/0`'s own
  fallback is `false`, so an install with no config block at all stays off — fail-safe, mirroring
  `Cinder.Download.StallReaper`.)
  """

  # Executables and shortcuts. Deliberately excludes archive formats a real release uses
  # (.rar/.zip/.7z/.par2) — `.zipx` is here because no media release ships one.
  @default_blocked_extensions ~w(.lnk .exe .bat .cmd .com .scr .pif .msi .vbs .js .ps1 .zipx)

  @doc "Whether the content check runs (`config :cinder, #{inspect(__MODULE__)}, enabled: true`)."
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc "The extensions that mark a download as a fake, lowercase and dot-prefixed."
  def blocked_extensions,
    do: Keyword.get(config(), :blocked_extensions, @default_blocked_extensions)

  @doc """
  `{:blocked, detail}` when any name in `filenames` carries a blocked extension, else `:ok`.
  `detail` names the offending file for the operator-facing park/re-queue reason. An empty list
  (a torrent that has not fetched metadata yet) is `:ok`.
  """
  def check(filenames) when is_list(filenames) do
    blocked = blocked_extensions()

    Enum.find_value(filenames, :ok, fn
      name when is_binary(name) ->
        if String.downcase(Path.extname(name)) in blocked,
          do: {:blocked, "download contains #{Path.basename(name)}"}

      _name ->
        nil
    end)
  end

  @doc """
  `check/1` over the file list `client` reports for `download_id` — what both pollers call on an
  in-flight download. `:ok` when disabled, when the client has no opinion, and when the client
  call fails outright.

  ## ponytail: one client call per in-flight download per tick

  Only while enabled, and at household scale that is a handful of local calls. If a big queue ever
  makes it measurable, cache the verdict on the row rather than sampling ticks — a fake has to be
  caught on the first look, not the tenth.
  """
  def vet(client, download_id) do
    if enabled?(), do: vet_files(client, download_id), else: :ok
  end

  defp vet_files(client, download_id) do
    case client.files(download_id) do
      {:ok, files} -> check(files)
      {:error, _reason} -> :ok
    end
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
