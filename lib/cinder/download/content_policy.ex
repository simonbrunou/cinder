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

  ## Why the payload must be the *whole* download

  A blocked extension alone is not enough to condemn a release, because plenty of legitimate ones
  carry one: RARBG-lineage torrents ship a 0-byte `RARBG_DO_NOT_MIRROR.exe` next to the video, and
  that is a large share of public-tracker content. Blocking on presence would re-queue and
  blocklist every such candidate with no retry budget until the title hit `:no_match` — the check
  would cost the household its library rather than protect it.

  So a download is blocked only when it carries a blocked extension **and** nothing that could be
  the actual media: no video file, and no archive either (legitimate usenet and scene releases ship
  as `.rar`/`.par2` sets and only become video after unpacking). A fake carries a `.lnk` and a
  `readme.txt` and nothing else, which is exactly what this catches.

  Override either list per install with
  `config :cinder, #{inspect(__MODULE__)}, blocked_extensions: ~w(.lnk ...), media_extensions: ~w(.mkv ...)`.

  **On by default** — the shipped `config/config.exs` sets `enabled: true`. (`enabled?/0`'s own
  fallback is `false`, so an install with no config block at all stays off — fail-safe, mirroring
  `Cinder.Download.StallReaper`.)
  """

  alias Cinder.HTTPPolicy

  # Executables and shortcuts. Deliberately excludes archive formats a real release uses
  # (.rar/.zip/.7z/.par2) — `.zipx` is here because no media release ships one.
  @default_blocked_extensions ~w(.lnk .exe .bat .cmd .com .scr .pif .msi .vbs .js .ps1 .zipx)

  # Anything that could plausibly BE the media: playable containers, plus the archive/parity set a
  # release arrives in before unpacking. One of these present means the download has real content
  # and the blocked file is a companion, not the payload.
  @default_media_extensions ~w(
    .mkv .mp4 .avi .m4v .mov .wmv .ts .m2ts .mpg .mpeg .webm .flv .ogm .iso .img
    .rar .zip .7z .par2 .tar .gz .001
  )

  @doc "Whether the content check runs (`config :cinder, #{inspect(__MODULE__)}, enabled: true`)."
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc """
  The extensions that mark a download as a fake, dot-prefixed. Downcased on read so an operator
  who configures `.EXE` doesn't get a silently dead entry.
  """
  def blocked_extensions,
    do: config() |> Keyword.get(:blocked_extensions, @default_blocked_extensions) |> downcase()

  @doc "The extensions that mean a download carries real content, dot-prefixed."
  def media_extensions,
    do: config() |> Keyword.get(:media_extensions, @default_media_extensions) |> downcase()

  @doc """
  `{:blocked, detail}` when `filenames` carries a blocked extension **and** nothing that could be
  the actual media, else `:ok`. `detail` names the offending file for the operator-facing
  park/re-queue reason. An empty list (a torrent that has not fetched metadata yet) is `:ok`.
  """
  def check(filenames) when is_list(filenames) do
    extensions = for name <- filenames, is_binary(name), do: {name, extension(name)}

    with {name, _ext} <- Enum.find(extensions, &(elem(&1, 1) in blocked_extensions())),
         false <- Enum.any?(extensions, &(elem(&1, 1) in media_extensions())) do
      {:blocked, detail(name)}
    else
      _has_real_content_or_nothing_blocked -> :ok
    end
  end

  # Normalized, because a bare `Path.extname/1` match is defeated by one appended byte:
  # `evil.exe.` reads as `"."`, `evil.exe ` as `".exe "`, `evil.exe:$DATA` as `".exe:$DATA"`.
  # All three still name an executable to the household member who opens the download share —
  # Windows canonicalization drops trailing dots and spaces, and `f.exe:$DATA` IS `f.exe` (an
  # alternate data stream) — so the check has to see through them or it is evaded for free.
  defp extension(name) do
    name
    |> Path.basename()
    # An alternate-data-stream suffix is everything from the first `:`.
    |> String.split(":", parts: 2)
    |> hd()
    |> String.replace(~r/[\s.]+$/u, "")
    |> Path.extname()
    |> String.downcase()
  end

  # The name is remote, attacker-chosen and unbounded, and this string is both logged and
  # persisted as the park reason — so it goes through the same sanitizer (CRLF stripped,
  # truncated) that every other remote string in the pollers already uses.
  defp detail(name), do: "download contains #{HTTPPolicy.sanitize_log(Path.basename(name))}"

  defp downcase(extensions), do: Enum.map(extensions, &String.downcase/1)

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
