defmodule Cinder.Indexers.Definitions.Source.GitHub do
  @moduledoc """
  Reads Prowlarr/Indexers from GitHub with two plain HTTPS GETs and no GitHub REST call, whose
  unauthenticated limit is 60 calls an hour per IP, a 304 included (#1616 point 2):

  - `master_commit/0` reads
    `https://github.com/Prowlarr/Indexers.git/info/refs?service=git-upload-pack`, the ref
    advertisement a git client reads first, capped at 1 MiB (55,512 bytes measured) under a 30 s
    deadline. The body must be pkt-lines (four lowercase hex digits giving each line's length,
    its own four included, at most 65,520) shaped as git's smart HTTP protocol sends them: the
    line `# service=git-upload-pack` and a flush, then the ref lines and a closing flush, then
    nothing. The commit comes from the one ref line whose payload is a 40-character lowercase
    hex id, a space and exactly `refs/heads/master`, then nothing, a line feed, or a NUL and the
    capabilities. Any other shape, no such line or two of them is `:no_master_ref`.
  - `download/1` reads `https://codeload.github.com/Prowlarr/Indexers/zip/<commit>`, capped at
    16 MiB (1,422,365 bytes measured) under a 120 s deadline, for a commit of exactly 40
    lowercase hex characters; any other commit is `:invalid_commit` before any request.

  Each request is a GET to its fixed URL, query included, with `redirect: false` and
  `retry: false`, set after the configured `req_options`, which cannot change them: a 3xx is
  `{:http_status, status}`, and the request is sent once. It goes through `Cinder.HTTPPolicy.bounded_request/3`. The adapter
  drops the response's `content-type` before `bounded_request/3` reads it, so a body labelled
  JSON stays the raw bytes rather than being decoded. A status other than 200 is
  `{:http_status, status}`. The deadline and the cap end a request as `:timeout` and
  `:too_large`, a receive timeout as `:timeout`, and any other failure as `:transport`. No error
  carries the URL, a header or a body byte.

  Config (`config :cinder, #{inspect(__MODULE__)}`): `req_options`, merged into each request
  (the test env routes them to a `Req.Test` stub), and `deadline_ms`, a test seam that replaces
  both deadlines.
  """

  @behaviour Cinder.Indexers.Definitions.Source

  alias Cinder.HTTPPolicy

  @info_refs_url "https://github.com/Prowlarr/Indexers.git/info/refs?service=git-upload-pack"
  @zip_url "https://codeload.github.com/Prowlarr/Indexers/zip/"

  @info_refs_max_bytes 1_048_576
  @info_refs_deadline_ms 30_000
  @zip_max_bytes 16_777_216
  @zip_deadline_ms 120_000

  # gitprotocol-common: "The maximum length of a pkt-line's data component is 65516 bytes",
  # 65,520 with the four length digits.
  @max_pkt_length 65_520

  @impl true
  def master_commit do
    with {:ok, body} <- get(@info_refs_url, @info_refs_max_bytes, @info_refs_deadline_ms) do
      master_ref(body)
    end
  end

  @impl true
  def download(commit) when is_binary(commit) do
    if commit?(commit),
      do: get(@zip_url <> commit, @zip_max_bytes, @zip_deadline_ms),
      else: {:error, :invalid_commit}
  end

  defp commit?(id), do: id =~ ~r/\A[0-9a-f]{40}\z/

  defp get(url, max_bytes, deadline_ms) do
    config = Application.get_env(:cinder, __MODULE__, [])

    config
    |> Keyword.get(:req_options, [])
    |> Keyword.merge(method: :get, url: url, params: [], redirect: false, retry: false)
    |> Req.new()
    |> Req.Request.append_response_steps(raw_body: &drop_content_type/1)
    |> HTTPPolicy.bounded_request(max_bytes, Keyword.get(config, :deadline_ms, deadline_ms))
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, :request_timeout} -> {:error, :timeout}
      {:error, :response_too_large} -> {:error, :too_large}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, _reason} -> {:error, :transport}
    end
  end

  # `HTTPPolicy.bounded_request/3` decodes a body whose content type is JSON once Req returns,
  # before the status reaches this adapter. Neither endpoint answers JSON, so the label is dropped
  # and the bytes reach the parsers as they came.
  defp drop_content_type({request, response}),
    do: {request, Req.Response.delete_header(response, "content-type")}

  # --- the ref advertisement ---

  defp master_ref(body) do
    with {:ok, packets} <- pkt_lines(body, []),
         ["# service=git-upload-pack\n", :flush | refs] <- packets,
         [:flush | refs] <- Enum.reverse(refs),
         false <- :flush in refs,
         [commit] <- Enum.flat_map(refs, &master_line/1) do
      {:ok, commit}
    else
      _no_master_ref -> {:error, :no_master_ref}
    end
  end

  defp pkt_lines(<<>>, packets), do: {:ok, Enum.reverse(packets)}
  defp pkt_lines(<<"0000", rest::binary>>, packets), do: pkt_lines(rest, [:flush | packets])

  defp pkt_lines(<<length::binary-size(4), rest::binary>>, packets) do
    with true <- length =~ ~r/\A[0-9a-f]{4}\z/,
         size when size in 4..@max_pkt_length <- String.to_integer(length, 16),
         payload_size = size - 4,
         <<payload::binary-size(^payload_size), rest::binary>> <- rest do
      pkt_lines(rest, [payload | packets])
    else
      _broken -> :error
    end
  end

  defp pkt_lines(_cut, _packets), do: :error

  defp master_line(<<id::binary-size(40), " refs/heads/master", tail::binary>>) do
    if commit?(id) and master_tail?(tail), do: [id], else: []
  end

  defp master_line(_payload), do: []

  defp master_tail?(""), do: true
  defp master_tail?("\n"), do: true
  defp master_tail?(<<0, _capabilities::binary>>), do: true
  defp master_tail?(_other), do: false
end
