defmodule Cinder.Download.Client.Fetch do
  @moduledoc """
  Fetches a release's download link for a download client, through the redirect-checked,
  size-bounded request of `Cinder.HTTPPolicy`.

  `answer/3` returns the answer itself: `{:ok, answer}` with the final hop's `:status`, `:headers`,
  `:body` and `:url`, `:trusted`, true while every hop stayed on the link's source origin, and
  `:login_redirect`, true only on the answer of a login redirect it did not follow. It follows up to
  five redirects. A redirect to a magnet is `{:magnet, link}` when `opts` sets `allow_magnet: true`,
  else `{:error, :unsupported_download_url}`. A redirect with no Location is
  `{:error, {error_tag, status}}`. A redirect on the source origin whose target path ends in
  `/login` is not followed: its own answer is returned with the target as `:url` and
  `login_redirect: true`, so the check reads it as a login redirect even when the login page would
  not answer, unless the five redirects are spent, which is `{:error, :too_many_redirects}`. Every
  other failure is `{:error, reason}`, where `reason` holds no URL: an atom, a tag with an atom or
  an integer, or a `Req.TransportError` or `Req.HTTPError` whose reason is an atom. A transport
  error or a URL error can quote the request target, query and key included, so such a reason keeps
  only its class: an `HTTPError`'s tag, `:invalid_url` for a refused URL's text, else
  `:fetch_failed`.

  `bytes/3` is `answer/3` followed by `Cinder.Download.Client.DownloadCheck.check/2`, which hands
  a client only a recognised file (#1658).
  """

  alias Cinder.Download.Client.DownloadCheck
  alias Cinder.Download.Torrent
  alias Cinder.HTTPPolicy

  @max_redirects 5

  @type answer :: %{
          status: integer(),
          headers: %{optional(String.t()) => [String.t()]},
          body: term(),
          url: URI.t(),
          trusted: boolean(),
          login_redirect: boolean()
        }

  @doc "`answer/3` read through `DownloadCheck.check/2`; see the moduledoc."
  @spec bytes(String.t(), String.t() | nil, keyword()) ::
          {:ok, binary()} | {:magnet, String.t()} | {:error, term()}
  def bytes(url, source_origin, opts) when is_binary(url) do
    url |> answer(source_origin, opts) |> DownloadCheck.check(opts)
  end

  @doc "The link's answer, before any check of its body; see the moduledoc."
  @spec answer(String.t(), String.t() | nil, keyword()) ::
          {:ok, answer()} | {:magnet, String.t()} | {:error, term()}
  def answer(url, source_origin, opts) when is_binary(url) do
    case fetch(url, source_origin, Keyword.put_new(opts, :redirects, @max_redirects)) do
      {:error, reason} -> {:error, closed_reason(reason)}
      answer -> answer
    end
  end

  defp closed_reason(reason) when is_atom(reason), do: reason

  defp closed_reason({tag, value} = reason)
       when is_atom(tag) and (is_atom(value) or is_integer(value)),
       do: reason

  defp closed_reason({tag, _value}) when is_atom(tag), do: tag
  defp closed_reason(%Req.TransportError{reason: reason} = error) when is_atom(reason), do: error
  defp closed_reason(%Req.HTTPError{reason: reason} = error) when is_atom(reason), do: error

  defp closed_reason(%Req.HTTPError{reason: reason} = error)
       when is_tuple(reason) and is_atom(elem(reason, 0)),
       do: %{error | reason: elem(reason, 0)}

  defp closed_reason(reason) when is_binary(reason), do: :invalid_url
  defp closed_reason(_reason), do: :fetch_failed

  @doc """
  Checks a release's own `download_url` before its first request, as
  `Cinder.HTTPPolicy.source_request_target/2,3` does. `resolver` is a DNS resolver function, or
  `nil` for the real lookup.

  A refusal that `Cinder.HTTPPolicy.text_refusal?/1` names reads as `:unsupported_download_url`.
  The stored link and its source origin never change between retries, so no retry could fix it,
  and `Cinder.Download` drops the reservation instead (#1230). Every other answer is
  `source_request_target`'s own: a refusal that depends on DNS stays retryable. A redirect's
  Location never comes through here, since a remote server sends it and can change it.
  """
  def download_url_target(url, source_origin, resolver) do
    case request_target(url, source_origin, resolver) do
      {:error, reason} = error ->
        if HTTPPolicy.text_refusal?(reason), do: {:error, :unsupported_download_url}, else: error

      {:ok, target} ->
        {:ok, target}
    end
  end

  defp fetch(url, source_origin, opts) do
    with {:ok, target} <- download_url_target(url, source_origin, Keyword.get(opts, :resolver)) do
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
      |> Req.Request.append_response_steps(hide_content_type: &hide_content_type/1)

    # `HTTPPolicy.bounded_request/2` makes a caller's `:receive_timeout` past 60 s each hop's
    # total deadline too: the torrent fetches of Transmission and qBittorrent set 90 s (#1410).
    # NZBGet's fetch sets none and SABnzbd's sets 15 s: both keep 15 s per wait within a 60 s
    # deadline.
    case HTTPPolicy.bounded_request(request, Keyword.fetch!(opts, :max_bytes)) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        redirect(response, target.uri, trust, opts)

      {:ok, response} ->
        {:ok, answer_of(response, target.uri, trust)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `HTTPPolicy.bounded_request/2` decodes a body labelled JSON, and answers a body that does not
  # decode as `{:error, :invalid_json}` with no status. The label moves aside before it looks, so
  # every body reaches the check as the bytes that came, and comes back in the answer. It waits in
  # the response's private map, which no server header can fill.
  defp hide_content_type({request, response}) do
    case Req.Response.get_header(response, "content-type") do
      [] ->
        {request, response}

      values ->
        response = Req.Response.delete_header(response, "content-type")
        {request, Req.Response.put_private(response, :cinder_content_type, values)}
    end
  end

  defp answer_of(response, uri, trust) do
    content_type = Req.Response.get_private(response, :cinder_content_type)

    %{
      status: response.status,
      headers:
        if(content_type,
          do: Map.put(response.headers, "content-type", content_type),
          else: response.headers
        ),
      body: response.body,
      url: uri,
      trusted: match?({:source, _origin}, trust),
      login_redirect: false
    }
  end

  defp redirect(response, current, trust, opts) do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        cond do
          not Torrent.magnet?(location) ->
            follow_redirect(response, current, location, trust, opts)

          Keyword.get(opts, :allow_magnet, false) ->
            {:magnet, location}

          true ->
            {:error, :unsupported_download_url}
        end

      [] ->
        {:error, {Keyword.fetch!(opts, :error_tag), response.status}}
    end
  end

  defp follow_redirect(response, current, location, trust, opts) do
    if opts[:redirects] == 0 do
      {:error, :too_many_redirects}
    else
      case resolve_redirect(current, location, trust, opts) do
        {:ok, next, next_trust} ->
          hop(response, next, next_trust, opts)

        {:error, :unsupported_scheme} ->
          {:error, :unsupported_download_url}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A redirect on the source origin to a login path is not followed: its own answer, with the
  # target as its URL, is the login sign the check reads.
  defp hop(response, next, trust, opts) do
    if match?({:source, _origin}, trust) and login_path?(next.uri),
      do: {:ok, %{answer_of(response, next.uri, trust) | login_redirect: true}},
      else: request(next, trust, Keyword.update!(opts, :redirects, &(&1 - 1)))
  end

  # Whether `uri`'s path ends in `/login`, in any case: the target of a login redirect.
  defp login_path?(%URI{path: path}) when is_binary(path),
    do: path |> String.downcase(:ascii) |> String.ends_with?("/login")

  defp login_path?(%URI{}), do: false

  defp target(url, source_origin, opts),
    do: request_target(url, source_origin, Keyword.get(opts, :resolver))

  defp request_target(url, source_origin, resolver) when is_function(resolver, 1),
    do: HTTPPolicy.source_request_target(url, source_origin, resolver)

  defp request_target(url, source_origin, nil),
    do: HTTPPolicy.source_request_target(url, source_origin)

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
