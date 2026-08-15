defmodule Cinder.Library.MovieSources do
  @moduledoc """
  Resolves a movie download to one ordinary video or one proven native media-server stack.

  Archive and disc releases fail before the ordinary largest-video policy can mistake a sample
  or playlist segment for the feature. A stack is accepted only when every video has the same
  normalized stem and a contiguous `cd`/`disc`/`disk`/`part` suffix starting at one.
  """

  alias Cinder.Library

  def resolve(path) do
    case Library.safe_walk(path) do
      {:ok, files} -> resolve_folder(files)
      {:error, :enotdir} -> resolve_file(path)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_folder(files) do
    with {:ok, sources} <- classify(files),
         {:ok, sources} <- validate(sources),
         do: {:ok, sources, true}
  end

  defp resolve_file(path) do
    cond do
      disc_path?(path) ->
        {:error, :unsupported_disc}

      archive_file?(path) ->
        {:error, :unsupported_archive}

      true ->
        with {:ok, source} <- Library.safe_source_file(path), do: {:ok, [{source, nil}], false}
    end
  end

  defp validate(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn {path, part}, {:ok, valid} ->
      case Library.safe_source_file(path) do
        {:ok, source} -> {:cont, {:ok, [{source, part} | valid]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      {:error, _reason} = error -> error
    end
  end

  defp classify(files) do
    paths = Enum.map(files, &elem(&1, 0))
    videos = Enum.filter(files, fn {path, _size} -> Library.video_file?(path) end)
    parts = Enum.map(videos, fn {path, _size} -> {path, stack_part(path)} end)

    cond do
      Enum.any?(paths, &disc_path?/1) -> {:error, :unsupported_disc}
      Enum.any?(paths, &archive_file?/1) -> {:error, :unsupported_archive}
      videos == [] -> {:error, :no_video_file}
      Enum.any?(parts, fn {_path, part} -> not is_nil(part) end) -> strict_stack(parts)
      true -> {:ok, [{pick_video(videos), nil}]}
    end
  end

  defp stack_part(path) do
    stem = path |> Path.basename() |> Path.rootname()

    case Regex.named_captures(
           ~r/^(?<title>.+?)[ ._-]+(?:cd|disc|disk|part)[ ._-]?(?<part>\d{1,2})$/iu,
           stem
         ) do
      %{"title" => title, "part" => part} ->
        {normalize_title(title), String.to_integer(part)}

      nil ->
        nil
    end
  end

  defp normalize_title(title),
    do: title |> String.downcase() |> String.replace(~r/[ ._-]+/u, " ")

  defp strict_stack(parts) do
    parsed = Enum.map(parts, &elem(&1, 1))

    if Enum.any?(parsed, &is_nil/1),
      do: {:error, :ambiguous_multipart_movie},
      else: validate_stack(parts, parsed)
  end

  defp validate_stack(parts, parsed) do
    titles = parsed |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    numbers = parsed |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    if length(numbers) > 1 and length(titles) == 1 and
         numbers == Enum.to_list(1..length(numbers)) do
      {:ok,
       parts
       |> Enum.map(fn {path, {_title, part}} -> {path, part} end)
       |> Enum.sort_by(&elem(&1, 1))}
    else
      {:error, :ambiguous_multipart_movie}
    end
  end

  defp archive_file?(path) do
    extension = String.downcase(Path.extname(path))
    extension == ".rar" or Regex.match?(~r/^\.r\d{2}$/u, extension)
  end

  defp disc_path?(path) do
    String.downcase(Path.extname(path)) == ".iso" or
      Enum.any?(Path.split(path), &(String.upcase(&1) in ["BDMV", "VIDEO_TS"]))
  end

  # Largest video wins for an ordinary non-stack folder; path breaks size ties deterministically.
  defp pick_video(videos) do
    videos
    |> Enum.sort_by(fn {path, size} -> {-size, path} end)
    |> hd()
    |> elem(0)
  end
end
