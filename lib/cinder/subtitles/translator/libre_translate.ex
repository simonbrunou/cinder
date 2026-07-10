defmodule Cinder.Subtitles.Translator.LibreTranslate do
  @moduledoc false

  @behaviour Cinder.Subtitles.Translator

  @impl true
  def translate(cues, target) when is_list(cues) do
    with base when is_binary(base) and base != "" <- cfg(:base_url),
         {:ok, %{status: 200, body: %{"translatedText" => translated}}}
         when is_list(translated) and length(translated) == length(cues) <-
           Req.post(
             String.trim_trailing(base, "/") <> "/translate",
             Keyword.merge(
               [
                 json: request_body(cues, target),
                 receive_timeout: 15_000,
                 connect_options: [timeout: 5_000]
               ],
               req_options()
             )
           ) do
      {:ok, translated}
    else
      nil -> {:error, :not_configured}
      "" -> {:error, :not_configured}
      {:ok, %{status: 200}} -> {:error, :invalid_response}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp request_body(cues, target) do
    body = %{"q" => cues, "source" => "auto", "target" => target, "format" => "html"}

    case cfg(:api_key) do
      api_key when is_binary(api_key) and api_key != "" -> Map.put(body, "api_key", api_key)
      _ -> body
    end
  end

  defp req_options, do: cfg(:req_options) || []

  defp cfg(field) do
    :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(field)
  end
end
