defmodule Cinder.Acquisition.Indexer.Cardigann.Session do
  @moduledoc """
  The login session of a Cardigann definition with a `login` block (#1680): its cookie jar,
  stored in `Cinder.Acquisition.IndexerSource.Native.IndexerCookies`, and when to log in
  (`Cinder.Acquisition.Indexer.Cardigann.Login`).

  A session starts `:unloaded`. Its first request reads the stored row: a row that reads is the
  session, and a miss (no row, an expired or unreadable one, one of an older
  `credentials_version`) logs in first. Each request goes out with the session's cookies, and a
  `Set-Cookie` from a credential host updates the jar and the row (`IndexerCookies.update/3`).

  An answer is classed before anything starts a login (`exchange/4`): only a login sign
  (`Login.sign/4`) does. Then the session logs in once and sends the request again once. A
  resend that still shows a login sign is rejected credentials,
  `{:rejected_credentials, {:login_rejected, method}}`, and so is any login sign of the `cookie`
  method, which has nothing to log in with but the cookie the admin saved. A resend answered
  with a limit or a failure reads as that.

  A login's own answer is recorded inside the hold of its last request: a stored jar on
  success, else its class (`{:login_rejected, method}` for a refused login). A login that fails
  before its first request (`Login.run/2`'s `{:unsent, class}`) records its class once it
  returns. Before its first
  request, the login reads the row again inside its hold, so a search that waited behind
  another search's login takes that login and sends none (`Login.run/2`'s `fresh`).

  Each request is one call of the run's `hold`: the search's lease slot with its gate and
  spacing, the Test's slot with no gate, or none for a grab. A run with `record?: false` (the
  Test) records no answer in `IndexerStatus`, and its caller records the answer.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{Fetch, Login}
  alias Cinder.Acquisition.Indexer.NewznabAnswer
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerCaptchas, IndexerCookies, IndexerStatus}

  @type t :: %{
          jar: Cinder.Acquisition.Indexer.Cardigann.Jar.t(),
          logged_in_at: DateTime.t(),
          logged_in?: boolean()
        }

  @typedoc """
  What a session's requests run under: the configured indexer, its running copy, the request
  context, the hold each request runs in, whether answers are recorded, and keys a login's
  requests take over the copy's (`request`, a grab's resolver and plug).
  """
  @type run :: %{
          required(:indexer) => Cinder.Indexers.ConfiguredIndexer.t(),
          required(:copy) => map(),
          required(:context) => map(),
          required(:hold) => ((-> term()) -> {:ran, term()} | {:not_run, term()}),
          required(:record?) => boolean(),
          optional(:request) => map()
        }

  @doc """
  The binding a captcha session of `copy` is stored and taken under (#1681): the base URL the
  copy runs under and the running copy's hash.
  """
  @spec captcha_binding(map()) :: IndexerCaptchas.binding()
  def captcha_binding(copy),
    do: %{address: copy.config.base_url, blob_sha: Map.get(copy, :blob_sha)}

  @doc "The session a request chain of `copy` starts with: nil for a definition with no login."
  @spec start(map()) :: :unloaded | nil
  def start(%{definition: %{login: %{}}}), do: :unloaded
  def start(_copy), do: nil

  @doc """
  The session `session` stands for: a loaded one as it is; for `:unloaded`, the stored row, or a
  login when it reads none. Answers `{:ok, session}`, `{:error, class}` or `{:not_run, outcome}`.
  """
  @spec load(run(), :unloaded | t()) :: {:ok, t()} | {:error, term()} | {:not_run, term()}
  # A run that carries a captcha answer logs in with it, whatever row is stored.
  def load(%{captcha: %{}} = run, :unloaded), do: login(run, nil)

  def load(run, :unloaded) do
    case IndexerCookies.read(run.indexer, now()) do
      {:ok, stored} -> {:ok, Map.put(stored, :logged_in?, false)}
      :miss -> login(run, nil)
    end
  end

  def load(_run, session), do: {:ok, session}

  @doc """
  Logs in once for `run`, after `session` (nil before any) showed a login sign; see the
  moduledoc. Answers the new session, `{:error, class}` with the class recorded when the run
  records, or `{:not_run, outcome}`.
  """
  @spec login(run(), t() | nil) :: {:ok, t()} | {:error, term()} | {:not_run, term()}
  def login(run, session) do
    case Login.method(run.copy.definition) do
      :cookie -> seeded(run)
      _method -> logged_in(run, session)
    end
  end

  defp seeded(run) do
    now = now()

    case Login.seed(run.copy, now) do
      {:ok, jar} ->
        IndexerCookies.store_login(run.indexer, jar, now)
        {:ok, %{jar: jar, logged_in_at: now, logged_in?: true}}

      {:error, class} ->
        {:error, record(run, class, now)}
    end
  end

  defp logged_in(run, session) do
    seen_at = if session, do: session.logged_in_at

    opts = %{
      context: run.context,
      hold: login_hold(run),
      fresh: fn -> fresh(run, seen_at) end,
      request: Map.get(run, :request, %{})
    }

    login_answer(run, Login.run(run.copy, with_captcha(opts, run)))
  end

  # The captcha answer's login (#1681): the load's session, taken inside the hold of the
  # login's first request, and the answer.
  defp with_captcha(opts, %{captcha: %{token: token, answer: answer}} = run) do
    take = fn -> IndexerCaptchas.take(run.indexer.id, token, captcha_binding(run.copy), now()) end
    Map.put(opts, :captcha, %{take: take, answer: answer})
  end

  defp with_captcha(opts, _run), do: opts

  defp login_answer(_run, {:logged_in, session}), do: {:ok, session}
  defp login_answer(_run, {:fresh, stored}), do: {:ok, Map.put(stored, :logged_in?, true)}
  defp login_answer(_run, {:rejected, method}), do: {:error, rejected(method)}
  defp login_answer(_run, {:error, class}), do: {:error, class}
  defp login_answer(_run, {:not_run, outcome}), do: {:not_run, outcome}
  # A login that failed before its first request, so no hold recorded it; a captcha session it
  # never took is discarded, since its answer is gone with this run.
  defp login_answer(run, {:unsent, class}) do
    if Map.has_key?(run, :captcha), do: IndexerCaptchas.delete(run.indexer.id)
    {:error, record(run, class, now())}
  end

  # `Login.run/2`'s `fresh`: the stored row when it holds a login other than the one this
  # session already used.
  defp fresh(run, seen_at) do
    case IndexerCookies.read(run.indexer, now()) do
      {:ok, stored} -> if same_login?(stored, seen_at), do: :none, else: {:use, stored}
      :miss -> :none
    end
  end

  # The row holds the login this session already used: its time, whatever its precision.
  defp same_login?(_stored, nil), do: false
  defp same_login?(stored, seen_at), do: DateTime.compare(stored.logged_in_at, seen_at) == :eq

  # Inside the hold of a login's last request: the jar stored on success, the class recorded
  # otherwise.
  defp login_hold(run), do: fn fun -> run.hold.(fn -> held_login(run, fun.()) end) end

  defp held_login(run, {:done, {:ok, jar}}) do
    now = now()
    IndexerCookies.store_login(run.indexer, jar, now)
    {:done, {:logged_in, %{jar: jar, logged_in_at: now, logged_in?: true}}}
  end

  defp held_login(run, {:done, {:rejected, method}} = done) do
    record(run, rejected(method), now())
    done
  end

  defp held_login(run, {:done, :captcha_required}),
    do: {:done, {:error, record(run, captcha_required(), now())}}

  defp held_login(run, {:done, :captcha_expired}),
    do: {:done, {:error, record(run, :captcha_expired, now())}}

  defp held_login(run, {:done, {:error, class}}), do: {:done, {:error, record(run, class, now())}}
  defp held_login(_run, step), do: step

  @doc """
  Sends `outgoing` for `run` under `session` (`:unloaded` or loaded) as the moduledoc says, and
  answers what `finish` makes of the answer that showed no login sign, called inside the hold:
  `finish.(answer, request, now)` with `answer` `{:ok, Fetch.page()}` or `{:error, class}`,
  answering `{:ok, value}` or `{:error, class}`. Answers `{:ok, value, session}`,
  `{:error, class}` or `{:not_run, outcome}`.
  """
  @spec exchange(run(), Fetch.outgoing(), :unloaded | t(), function()) ::
          {:ok, term(), t()} | {:error, term()} | {:not_run, term()}
  def exchange(run, outgoing, session, finish) do
    # A first answer that shows no sign passes through the `with` as it is.
    with {:ok, session} <- load(run, session),
         {:sign, session} <- attempt(run, outgoing, session, finish),
         {:ok, session} <- login(run, session),
         do: attempt(run, outgoing, session, finish)
  end

  # One request under `session` in one hold.
  defp attempt(run, outgoing, session, finish) do
    case run.hold.(fn -> attempted(run, outgoing, session, finish) end) do
      {:ran, result} -> result
      {:not_run, outcome} -> {:not_run, outcome}
    end
  end

  defp attempted(run, outgoing, session, finish) do
    now = now()
    request = run.copy.request.(run.context, now)
    {answer, jar} = Fetch.send_session(outgoing, request, session.jar)
    session = kept(run, session, jar)

    case Login.sign(answer, run.copy.definition, request, run.context.deadline_at) do
      :sign -> signed(run, session, now)
      :none -> answer |> finish.(request, now) |> finished(session)
      {:error, class} -> finish.({:error, class}, request, now)
    end
  end

  defp finished({:ok, value}, session), do: {:ok, value, session}
  defp finished(error, _session), do: error

  # A login sign after this run's login, or any of the `cookie` method's: rejected credentials.
  defp signed(run, session, now) do
    method = Login.method(run.copy.definition)

    if session.logged_in? or method == :cookie,
      do: {:error, record(run, rejected(method), now)},
      else: {:sign, session}
  end

  defp kept(run, session, jar) do
    if jar != session.jar, do: IndexerCookies.update(run.indexer, session.logged_in_at, jar)
    %{session | jar: jar}
  end

  defp rejected(method), do: {:rejected_credentials, {:login_rejected, method}}

  # A `form` login whose landing page shows the definition's image captcha, with no answer from
  # the admin (#1681): rejected credentials, so no request goes out until an edit or a Test.
  defp captcha_required, do: {:rejected_credentials, :captcha_required}

  # Records `class` when the run records, and answers it with a limit's wait ended as the
  # status ends it, as a search page's answer is recorded.
  defp record(%{record?: true} = run, class, now) do
    IndexerStatus.record(run.indexer, class, now)

    case class do
      {:limit, wait} -> {:limit, NewznabAnswer.limit_until(wait, now)}
      class -> class
    end
  end

  defp record(_run, class, _now), do: class

  defp now, do: Native.now()
end
