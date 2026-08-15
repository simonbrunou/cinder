defmodule Cinder.Download.Client.Fetch do
  @moduledoc false

  alias Cinder.HTTPPolicy

  @max_redirects 5

  def bytes(url, source_origin, opts) when is_binary(url) do
    fetch(url, source_origin, Keyword.put_new(opts, :redirects, @max_redirects))
  end

  defp fetch(url, source_origin, opts) do
    with {:ok, target} <- target(url, source_origin, opts) do
      trust =
        if HTTPPolicy.same_origin?(target.uri, source_origin),
          do: {:source, source_origin},
          else: :untrusted

      request(target, trust, opts)
    end
  end

  defp request(target, trust, opts) do
    request =
      target
      |> HTTPPolicy.request_options(
        receive_timeout: Keyword.get(opts, :receive_timeout, 15_000),
        pool_timeout: 5_000,
        connect_options: [timeout: 5_000],
        retry: false,
        redirect: false,
        plug: Keyword.get(opts, :plug)
      )
      |> Req.new()

    case HTTPPolicy.bounded_request(request, Keyword.fetch!(opts, :max_bytes)) do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) ->
        {:ok, bytes}

      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        redirect(response, target.uri, trust, opts)

      {:ok, %{status: status}} ->
        {:error, {Keyword.fetch!(opts, :error_tag), status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redirect(response, current, trust, opts) do
    case Req.Response.get_header(response, "location") do
      ["magnet:" <> _ = magnet | _] ->
        if Keyword.get(opts, :allow_magnet, false),
          do: {:magnet, magnet},
          else: {:error, :unsupported_download_url}

      [location | _] ->
        follow_redirect(current, location, trust, opts)

      [] ->
        {:error, {Keyword.fetch!(opts, :error_tag), response.status}}
    end
  end

  defp follow_redirect(current, location, trust, opts) do
    if opts[:redirects] == 0 do
      {:error, :too_many_redirects}
    else
      case resolve_redirect(current, location, trust, opts) do
        {:ok, next, next_trust} ->
          request(next, next_trust, Keyword.update!(opts, :redirects, &(&1 - 1)))

        {:error, :unsupported_scheme} ->
          {:error, :unsupported_download_url}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp target(url, source_origin, opts) do
    case Keyword.get(opts, :resolver) do
      resolver when is_function(resolver, 1) ->
        HTTPPolicy.source_request_target(url, source_origin, resolver)

      nil ->
        HTTPPolicy.source_request_target(url, source_origin)
    end
  end

  defp resolve_redirect(current, location, {:source, source_origin}, opts) do
    case HTTPPolicy.resolve_redirect(current, location, :same_origin) do
      {:ok, next} ->
        with {:ok, target} <- target(next, source_origin, opts),
             do: {:ok, target, {:source, source_origin}}

      {:error, :cross_origin_redirect} ->
        resolve_untrusted_redirect(current, location, opts)

      error ->
        error
    end
  end

  defp resolve_redirect(current, location, :untrusted, opts),
    do: resolve_untrusted_redirect(current, location, opts)

  defp resolve_untrusted_redirect(current, location, opts) do
    case Keyword.get(opts, :resolver) do
      resolver when is_function(resolver, 1) ->
        with {:ok, next} <- HTTPPolicy.untrusted_redirect_target(current, location, resolver),
             do: {:ok, next, :untrusted}

      nil ->
        with {:ok, next} <- HTTPPolicy.untrusted_redirect_target(current, location),
             do: {:ok, next, :untrusted}
    end
  end
end
