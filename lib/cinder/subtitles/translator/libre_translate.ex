defmodule Cinder.Subtitles.Translator.LibreTranslate do
  @moduledoc false

  @behaviour Cinder.Subtitles.Translator

  # LibreTranslate on CPU translates sequentially and slowly, so the whole
  # file cannot go in one request under a short timeout. Split the cues into
  # small batches, translate them one at a time (the engine is CPU-bound with a
  # low thread ceiling, so concurrency would only contend), and concatenate in
  # order. Both knobs are config-overridable so the batch size can be tuned to a
  # given box's throughput without a code change.
  @default_batch_size 50
  @default_receive_timeout 60_000

  @impl true
  def translate(cues, target) when is_list(cues) do
    case cfg(:base_url) do
      base when is_binary(base) and base != "" ->
        translate_all(String.trim_trailing(base, "/") <> "/translate", cues, target)

      _ ->
        {:error, :not_configured}
    end
  end

  defp translate_all(url, cues, target) do
    cues
    |> Enum.chunk_every(batch_size())
    |> Enum.reduce_while({:ok, []}, &reduce_batch(url, target, &1, &2))
    |> finalize()
  end

  defp reduce_batch(url, target, batch, {:ok, acc}) do
    case translate_batch(url, batch, target) do
      {:ok, translated} -> {:cont, {:ok, [translated | acc]}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp finalize({:ok, chunks}), do: {:ok, chunks |> Enum.reverse() |> Enum.concat()}
  defp finalize({:error, _} = error), do: error

  defp translate_batch(url, cues, target) do
    case Req.post(url, req_args(cues, target)) do
      {:ok, %{status: 200, body: %{"translatedText" => translated}}}
      when is_list(translated) and length(translated) == length(cues) ->
        {:ok, translated}

      {:ok, %{status: 200}} ->
        {:error, :invalid_response}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp req_args(cues, target) do
    Keyword.merge(
      [
        json: request_body(cues, target),
        receive_timeout: receive_timeout(),
        connect_options: [timeout: 5_000]
      ],
      req_options()
    )
  end

  defp request_body(cues, target) do
    body = %{"q" => cues, "source" => "auto", "target" => target, "format" => "html"}

    case cfg(:api_key) do
      api_key when is_binary(api_key) and api_key != "" -> Map.put(body, "api_key", api_key)
      _ -> body
    end
  end

  defp batch_size do
    case cfg(:batch_size) do
      size when is_integer(size) and size > 0 -> size
      _ -> @default_batch_size
    end
  end

  defp receive_timeout do
    case cfg(:receive_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_receive_timeout
    end
  end

  defp req_options, do: cfg(:req_options) || []

  defp cfg(field) do
    :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(field)
  end
end
