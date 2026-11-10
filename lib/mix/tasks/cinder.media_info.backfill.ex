defmodule Mix.Tasks.Cinder.MediaInfo.Backfill do
  @shortdoc "Backfill audio/subtitle language info onto already-imported media"
  @moduledoc """
  Backfills audio and subtitle language info onto already-imported media
  (`Cinder.Library.Backfill.run/1`).

      mix cinder.media_info.backfill [--register-untracked]

  By default a subtitle file next to a video becomes Cinder-managed only in a language Cinder
  already manages for that video. `--register-untracked` also registers a `<video>.<lang>.srt`
  in a language Cinder does not manage yet, for media imported before Cinder recorded its
  subtitle files. Cinder cannot tell such a file from a subtitle you put next to the video
  yourself, so with this flag a hand-placed subtitle can become managed too, and the next
  subtitle fetch for a wanted language may replace it.

  A release has no Mix: run `Cinder.Library.Backfill.run/1` over `bin/cinder rpc` instead
  (`docs/operating.md`, "Media-info backfill").
  """
  use Mix.Task

  alias Cinder.Library.Backfill

  @impl true
  def run(args) do
    {switches, rest} = OptionParser.parse!(args, strict: [register_untracked: :boolean])

    if rest != [] do
      Mix.raise("mix cinder.media_info.backfill takes no arguments, only --register-untracked")
    end

    Mix.Task.run("app.start")
    Backfill.run(register_untracked: Keyword.get(switches, :register_untracked, false))
    Mix.shell().info("Media-info backfill complete.")
  end
end
