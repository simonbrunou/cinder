defmodule Cinder.CodeHealth.BeamVersionPinsTest do
  # #1040: three places pin the BEAM toolchain. CI's erlef/setup-beam steps set `otp-version` and
  # `elixir-version`, the Dockerfile's `ARG OTP_VERSION` and `ARG ELIXIR_VERSION` defaults form
  # the hexpm/elixir builder tag, and flake.lock's nixpkgs builds the dev shell. Renovate bumps
  # only the workflow, so on #729 the suite would have tested OTP 29.1.2 while the release built
  # on 29.1.1, with every CI job green. #1002 added a fourth: renovate.json's `constraints` set the
  # OTP and Elixir that Renovate installs before it runs `mix deps.update` for a security PR.
  # This fence fails when a setup-beam step, renovate.json and the Dockerfile disagree, and fails
  # rather than skips a pin it cannot read. It cannot see the flake, so its failure message says
  # how to check the dev shell.
  use ExUnit.Case, async: true

  @inputs %{"otp-version" => "OTP_VERSION", "elixir-version" => "ELIXIR_VERSION"}

  # The renovate.json `constraints` key that pins each setup-beam input's tool.
  @constraints %{"erlang" => "otp-version", "elixir" => "elixir-version"}

  # The presets renovate.json extends today. No preset built into Renovate 44.132.2 sets
  # `constraints`, so renovate.json's own key is the only one. A preset outside this list fails
  # until someone checks that it sets no `constraints` and adds it here. Forms the renovate.json
  # read does not follow include: a `constraints` key that a later Renovate release adds to one
  # of these presets.
  @presets ["config:recommended", "schedule:weekly"]

  # containerbase, which installs the tools for Renovate, names an OTP build with four numbers:
  # OTP 29.1.2 is 29.1.2.0, OTP 26.2.5.3 is 26.2.5.3. `install-tool erlang 29.1.2` fails with
  # "tool version not supported".
  @containerbase_otp ~r/\A\d+\.\d+\.\d+(?:\.\d+)?\z/

  # A full URL (https://data.forgejo.org/erlef/setup-beam@...) names the action too.
  @setup_beam ~r{(?:\A|/)setup-beam@}i

  # Three or more numbers (an OTP patch can have four, as 26.2.5.3 does), then an optional
  # pre-release such as -rc.1. A floating 29 or 1.20 does not match.
  @exact_version ~r/\A\d+(?:\.\d+){2,}(?:-[0-9A-Za-z.]+)?\z/

  @dockerfile ~S'''
  ARG ELIXIR_VERSION=1.20.4
  ARG OTP_VERSION=29.1.2
  ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-trixie"
  FROM ${BUILDER_IMAGE} AS builder
  '''

  @workflow ~S'''
  jobs:
    test:
      steps:
        - uses: actions/checkout@v7
        - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1
          id: beam
          with:
            otp-version: "29.1.2"
            elixir-version: "1.20.4"
    audit:
      steps:
        - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1
          with:
            otp-version: "29.1.2"
            elixir-version: "1.20.4"
  '''

  @renovate ~S'''
  {
    "extends": ["config:recommended", "schedule:weekly"],
    "constraints": {"erlang": "29.1.2.0", "elixir": "1.20.4"},
    "packageRules": [{"matchManagers": ["mix"], "enabled": false}]
  }
  '''

  test "every setup-beam step and renovate.json pin the Dockerfile's OTP and Elixir" do
    workflows =
      for path <- Path.wildcard(".{forgejo,github}/workflows/*.{yml,yaml}", match_dot: true),
          do: {path, File.read!(path)}

    problems =
      pin_problems(
        workflows,
        {"Dockerfile", File.read!("Dockerfile")},
        {"renovate.json", File.read!("renovate.json")}
      )

    assert problems == [],
           "The BEAM version pins disagree or cannot be read:\n  " <>
             Enum.join(problems, "\n  ") <>
             "\n\nMove these together: otp-version and elixir-version in every " <>
             "erlef/setup-beam step, the Dockerfile's ARG OTP_VERSION and ARG ELIXIR_VERSION " <>
             "defaults, renovate.json's constraints (erlang takes containerbase's " <>
             "four-number name, 29.1.2.0 for OTP 29.1.2), and flake.lock's nixpkgs. Check " <>
             "the dev shell with `nix develop . -c " <>
             "elixir -e 'IO.puts(:code.root_dir()); IO.puts(System.version())'`: the first " <>
             "line's erlang-<version> is its OTP. When hexpm/elixir has no tag for the new pair " <>
             "yet, the PR waits, since the release must run the OTP that CI tested (the " <>
             "container job's image build proves the tag exists). When no nixpkgs carries the " <>
             "new version yet, the flake may lag: say so in the PR body (docs/agents/ci.md " <>
             "\"Dependency rebuild\")."
  end

  test "the fixtures agree" do
    assert problems(@workflow) == []
  end

  test "an OTP or Elixir mismatch names the file, the step and both values" do
    assert problems(String.replace(@workflow, ~s("29.1.2"), ~s("29.1.1"))) == [
             ~s(ci.yml jobs.audit.steps[0]: otp-version "29.1.1", but Dockerfile's ) <>
               ~s(ARG OTP_VERSION is "29.1.2"),
             ~s(ci.yml jobs.test.steps[1]: otp-version "29.1.1", but Dockerfile's ) <>
               ~s(ARG OTP_VERSION is "29.1.2")
           ]

    dockerfile = String.replace(@dockerfile, "ELIXIR_VERSION=1.20.4", "ELIXIR_VERSION=1.20.3")

    assert problems(@workflow, dockerfile) == [
             ~s(ci.yml jobs.audit.steps[0]: elixir-version "1.20.4", but Dockerfile's ) <>
               ~s(ARG ELIXIR_VERSION is "1.20.3"),
             ~s(ci.yml jobs.test.steps[1]: elixir-version "1.20.4", but Dockerfile's ) <>
               ~s(ARG ELIXIR_VERSION is "1.20.3"),
             ~s(renovate.json constraints.elixir "1.20.4", but Dockerfile's ) <>
               ~s(ARG ELIXIR_VERSION is "1.20.3")
           ]
  end

  test "a renovate.json constraint that differs from the Dockerfile names both values" do
    renovate =
      @renovate
      |> String.replace(~s("29.1.2.0"), ~s("29.1.2"))
      |> String.replace(~s("1.20.4"), ~s("1.20.3"))

    assert renovate_problems(renovate) == [
             ~s(renovate.json constraints.elixir "1.20.3", but Dockerfile's ) <>
               ~s(ARG ELIXIR_VERSION is "1.20.4"),
             ~s(renovate.json constraints.erlang "29.1.2", but Dockerfile's ) <>
               ~s(ARG OTP_VERSION is "29.1.2", whose containerbase build is "29.1.2.0")
           ]

    assert renovate_problems(String.replace(@renovate, ~s("29.1.2.0"), "29.1")) == [
             ~s(renovate.json constraints.erlang 29.1, but Dockerfile's ) <>
               ~s(ARG OTP_VERSION is "29.1.2", whose containerbase build is "29.1.2.0")
           ]
  end

  test "an OTP pin with four numbers keeps them in renovate.json" do
    patch = &String.replace(&1, "29.1.2", "26.2.5.3")
    renovate = String.replace(@renovate, "29.1.2.0", "26.2.5.3")

    assert problems(patch.(@workflow), patch.(@dockerfile), renovate) == []

    assert problems(patch.(@workflow), patch.(@dockerfile), patch.(@renovate)) == [
             ~s(renovate.json constraints.erlang "26.2.5.3.0", but Dockerfile's ) <>
               ~s(ARG OTP_VERSION is "26.2.5.3")
           ]
  end

  test "an OTP pin with no containerbase name fails" do
    rc = &String.replace(&1, "29.1.2", "29.1.2-rc.1")

    assert problems(rc.(@workflow), rc.(@dockerfile), rc.(@renovate)) == [
             ~s(renovate.json constraints.erlang: Dockerfile's ARG OTP_VERSION "29.1.2-rc.1" ) <>
               "has no containerbase build name this check can derive"
           ]

    five = &String.replace(&1, "29.1.2", "26.2.5.3.1")
    renovate = String.replace(@renovate, "29.1.2.0", "26.2.5.3.1")

    assert problems(five.(@workflow), five.(@dockerfile), renovate) == [
             ~s(renovate.json constraints.erlang: Dockerfile's ARG OTP_VERSION "26.2.5.3.1" ) <>
               "has no containerbase build name this check can derive"
           ]
  end

  test "renovate.json without both constraints fails" do
    assert renovate_problems(~s({"extends": ["config:recommended"]})) == [
             "renovate.json sets no constraints"
           ]

    assert renovate_problems(~s({"constraints": ["29.1.2.0", "1.20.4"]})) == [
             ~s(renovate.json constraints is ["29.1.2.0", "1.20.4"], not an object)
           ]

    assert renovate_problems(~s({"constraints": {"erlang": "29.1.2.0"}})) == [
             "renovate.json constraints sets no elixir"
           ]
  end

  test "a renovate.json that is not a JSON object fails" do
    assert [unparsed] = renovate_problems(~s({"constraints": {"elixir": "1.20.4",}}))
    assert unparsed =~ ~r/\Arenovate\.json does not parse as JSON: /

    assert renovate_problems(~s(["config:recommended"])) == [
             "renovate.json is not a JSON object"
           ]
  end

  test "constraints below the top level or a preset outside the known ones fails" do
    renovate = ~S'''
    {
      "extends": ["config:recommended", "local>simonbrunou/renovate-config"],
      "constraints": {"erlang": "29.1.2.0", "elixir": "1.20.4"},
      "mix": {"constraints": {"erlang": "28.0.0.0"}},
      "packageRules": [
        {"matchManagers": ["mix"], "extends": "helpers:pinGitHubActionDigests"},
        {"matchPackageNames": ["bandit"], "constraints": {"elixir": "1.19.0"}}
      ]
    }
    '''

    assert renovate_problems(renovate) == [
             ~s(renovate.json extends: names "local>simonbrunou/renovate-config", ) <>
               "whose constraints this check cannot read",
             "renovate.json mix.constraints: sets constraints below the top level, " <>
               "which this check cannot read",
             ~s(renovate.json packageRules[0].extends: is "helpers:pinGitHubActionDigests", ) <>
               "not a list",
             "renovate.json packageRules[1].constraints: sets constraints below the top level, " <>
               "which this check cannot read"
           ]
  end

  test "a mismatch in one of two steps names that step only" do
    workflow = String.replace(@workflow, ~s("29.1.2"), ~s("29.1.1"), global: false)

    assert problems(workflow) == [
             ~s(ci.yml jobs.test.steps[1]: otp-version "29.1.1", but Dockerfile's ) <>
               ~s(ARG OTP_VERSION is "29.1.2")
           ]
  end

  test "a step whose pin is not a literal exact version fails" do
    assert step_problems(~S'''
           version-file: .tool-versions
           ''') == [
             ~s(ci.yml jobs.test.steps[0]: reads version-file ".tool-versions", ) <>
               "which this check cannot read",
             "ci.yml jobs.test.steps[0]: sets no elixir-version",
             "ci.yml jobs.test.steps[0]: sets no otp-version"
           ]

    assert step_problems(~S'''
           otp-version: ${{ matrix.otp }}
           elixir-version: "1.20.4"
           ''') == [
             ~s(ci.yml jobs.test.steps[0]: otp-version is "${{ matrix.otp }}", ) <>
               "not an exact major.minor.patch version"
           ]

    assert step_problems(~S'''
           otp-version: "29.1.2"
           ''') == ["ci.yml jobs.test.steps[0]: sets no elixir-version"]

    assert step_problems(~S'''
           otp-version: "29"
           elixir-version: 1.20
           ''') == [
             "ci.yml jobs.test.steps[0]: elixir-version is 1.2, " <>
               "not an exact major.minor.patch version",
             ~s(ci.yml jobs.test.steps[0]: otp-version is "29", ) <>
               "not an exact major.minor.patch version"
           ]
  end

  test "a setup-beam step without a with: mapping fails" do
    workflow = ~S'''
    jobs:
      test:
        steps:
          - uses: erlef/setup-beam@v1
    '''

    assert problems(workflow) == ["ci.yml jobs.test.steps[0]: with: is nil, not a mapping"]
  end

  test "a scan that finds no setup-beam step fails" do
    workflow = ~S'''
    jobs:
      test:
        steps:
          - uses: erlef/setup-elixir@v1
          - run: mix test
    '''

    assert problems(workflow) == [~s(found no erlef/setup-beam step in ["ci.yml"])]

    assert pin_problems([], {"Dockerfile", @dockerfile}, {"renovate.json", @renovate}) == [
             "found no erlef/setup-beam step in []"
           ]
  end

  test "a setup-beam input outside a setup-beam step fails" do
    workflow =
      @workflow <>
        ~S'''
          lint:
            steps:
              - uses: erlef/setup-elixir@v1
                with:
                  otp-version: "29.1.1"
        '''

    assert problems(workflow) == [
             ~s(ci.yml jobs.lint.steps[0].with: sets otp-version "29.1.1" outside an ) <>
               "erlef/setup-beam step"
           ]
  end

  test "a YAML alias or a file that does not parse fails" do
    workflow = ~S'''
    jobs:
      test:
        steps:
          - uses: erlef/setup-beam@v1
            with: &beam {otp-version: "29.1.2", elixir-version: "1.20.4"}
      audit:
        steps:
          - uses: erlef/setup-beam@v1
            with: *beam
    '''

    assert problems(workflow) == [
             "ci.yml:9: uses the YAML alias *beam, which this check cannot read",
             ~s(ci.yml jobs.audit.steps[0]: with: is "otp-version", not a mapping)
           ]

    assert [unparsed, _none] = problems("jobs: [unclosed\n")
    assert unparsed =~ ~r/\Aci\.yml does not parse as YAML: /
  end

  test "a comment or a run: block scalar naming a setup-beam input does not count" do
    workflow =
      @workflow <>
        ~S'''
          lint:
            steps:
              # otp-version: "29.1.1"
              - run: |
                  echo 'otp-version: "29.1.1"'
                  otp-version: "29.1.1"
                name: otp-version "29.1.1" # elixir-version: 1.20
        '''

    assert problems(workflow) == []
  end

  test "a flow-style step and with: read as a block mapping does" do
    workflow = ~S'''
    jobs:
      test:
        steps:
          - {uses: "erlef/setup-beam@v1", with: {otp-version: "29.1.1", elixir-version: "1.20.4"}}
          - uses: https://data.forgejo.org/ErlEF/setup-beam@v1
            with: {otp-version: "29.1.2", elixir-version: "1.20.4"}
    '''

    assert problems(workflow) == [
             ~s(ci.yml jobs.test.steps[0]: otp-version "29.1.1", but Dockerfile's ) <>
               ~s(ARG OTP_VERSION is "29.1.2")
           ]
  end

  test "the Dockerfile needs exactly one default for each ARG" do
    no_default = String.replace(@dockerfile, "ARG OTP_VERSION=29.1.2", "ARG OTP_VERSION")

    assert problems(@workflow, no_default) == ["Dockerfile sets no default for ARG OTP_VERSION"]

    two_defaults =
      String.replace(
        @dockerfile,
        "ARG OTP_VERSION=29.1.2",
        "ARG OTP_VERSION=29.1.2\nARG OTP_VERSION=29.1.1"
      )

    assert problems(@workflow, two_defaults) == [
             ~s(Dockerfile sets 2 defaults for ARG OTP_VERSION, "29.1.2" and "29.1.1", not one)
           ]

    floating = String.replace(@dockerfile, "OTP_VERSION=29.1.2", "OTP_VERSION=29")

    assert problems(@workflow, floating) == [
             ~s(Dockerfile's ARG OTP_VERSION default is "29", ) <>
               "not an exact major.minor.patch version"
           ]
  end

  test "the Dockerfile read skips comments and takes each ARG form" do
    dockerfile = ~S'''
    # ARG OTP_VERSION=29.1.1
      #ARG ELIXIR_VERSION=1.20.3
    # a comment line ending in the escape character continues nothing \
    arg ELIXIR_VERSION="1.20.4" OTP_VERSION=29.1.2
    FROM docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-trixie
    ARG OTP_VERSION
    '''

    assert problems(@workflow, dockerfile) == []

    # A comment after a Unicode space is still a comment.
    led = <<0xA0::utf8>> <> "# a comment that continues nothing either \\\n" <> dockerfile
    assert problems(@workflow, led) == []
  end

  test "a continued line before the first FROM fails" do
    dockerfile = ~S'''
    # escape=`
    ARG ELIXIR_VERSION=1.20.4 `
      OTP_VERSION=29.1.2
    ARG DEBIAN_VERSION=trixie \

      # Docker drops this comment and the blank line, so the next line continues the one above.
    ARG OTP_VERSION=29.1.2
    FROM debian
    RUN echo a \
      b
    '''

    assert problems(@workflow, dockerfile) == [
             "Dockerfile:2 continues onto the next line with `, which this check cannot read",
             "Dockerfile:4 continues onto the next line with \\, which this check cannot read",
             "Dockerfile sets no default for ARG ELIXIR_VERSION"
           ]

    # Docker strips every carriage return before a line feed, so this line continues too.
    crlf = "ARG ELIXIR_VERSION=1.20.4 OTP_VERSION=29.1.2 \\\r\r\nFROM debian\n"

    assert problems(@workflow, crlf) == [
             "Dockerfile:1 continues onto the next line with \\, which this check cannot read",
             "Dockerfile sets no default for ARG ELIXIR_VERSION",
             "Dockerfile sets no default for ARG OTP_VERSION"
           ]

    assert problems(@workflow, <<0xFF>> <> @dockerfile) == [
             "Dockerfile is not valid UTF-8, which this check cannot read",
             "Dockerfile sets no default for ARG ELIXIR_VERSION",
             "Dockerfile sets no default for ARG OTP_VERSION"
           ]
  end

  test "an ARG after the first FROM does not count" do
    # A stage's own default, or a heredoc body that reads like one, leaves the builder tag that
    # `FROM ${BUILDER_IMAGE}` already resolved as it was.
    dockerfile =
      String.replace(@dockerfile, "ARG OTP_VERSION=29.1.2", "ARG OTP_VERSION") <>
        ~S'''
        ARG OTP_VERSION=29.1.2
        RUN <<EOF cat > /tmp/a
        ARG OTP_VERSION=29.1.2
        EOF
        ONBUILD RUN <<EOF
        ARG OTP_VERSION=29.1.2
        EOF
        '''

    assert problems(@workflow, dockerfile) == ["Dockerfile sets no default for ARG OTP_VERSION"]

    # Docker skips a byte order mark, and the Unicode spaces before an instruction as it skips
    # ASCII ones, so neither may hide the first FROM or an ARG.
    stage = "FROM docker.io/hexpm/elixir:1.20.3-erlang-29.1.1-debian-trixie\n"

    for lead <- [<<0xFEFF::utf8>>, <<0xA0::utf8>>, " " <> <<0x2003::utf8>>] do
      assert {lead, problems(@workflow, lead <> stage <> @dockerfile)} ==
               {lead,
                [
                  "Dockerfile sets no default for ARG ELIXIR_VERSION",
                  "Dockerfile sets no default for ARG OTP_VERSION"
                ]}
    end

    spaced = String.replace(@dockerfile, "ARG OTP_VERSION", <<0xA0::utf8>> <> "ARG OTP_VERSION")
    assert problems(@workflow, spaced) == []
  end

  defp problems(workflow, dockerfile \\ @dockerfile, renovate \\ @renovate),
    do:
      pin_problems(
        [{"ci.yml", workflow}],
        {"Dockerfile", dockerfile},
        {"renovate.json", renovate}
      )

  defp renovate_problems(renovate), do: problems(@workflow, @dockerfile, renovate)

  defp step_problems(inputs) do
    indented = inputs |> String.split("\n", trim: true) |> Enum.map_join(&"          #{&1}\n")

    problems(
      "jobs:\n  test:\n    steps:\n      - uses: erlef/setup-beam@v1\n        with:\n" <> indented
    )
  end

  # Every problem in a set of workflows, `[{path, source}]`, a Dockerfile and a renovate.json, each
  # `{path, source}`, each naming its file and step, line or key. The real files and the fixtures
  # both go through here.
  defp pin_problems(workflows, {dockerfile, source}, renovate) do
    {pins, dockerfile_problems} = dockerfile_pins(dockerfile, source)
    read = Enum.map(workflows, fn {path, source} -> workflow_steps(path, source) end)
    steps = Enum.flat_map(read, &elem(&1, 0))

    none =
      if steps == [],
        do: ["found no erlef/setup-beam step in #{inspect(Enum.map(workflows, &elem(&1, 0)))}"],
        else: []

    mismatches =
      for {where, values} <- steps,
          {input, value} <- values,
          {:ok, pin} <- [Map.fetch(pins, input)],
          pin != value,
          do:
            ~s(#{where}: #{input} "#{value}", but #{dockerfile}'s ARG #{@inputs[input]} is "#{pin}")

    dockerfile_problems ++
      Enum.flat_map(read, &elem(&1, 1)) ++
      none ++ mismatches ++ renovate_pin_problems(renovate, {dockerfile, pins})
  end

  # Every problem in renovate.json against the Dockerfile's pins. Only the top-level `constraints`
  # is read, so the same key anywhere else (a packageRules entry, a manager block) fails, and so
  # does a preset outside @presets, since either could set the version Renovate installs.
  defp renovate_pin_problems({path, source}, dockerfile_pins) do
    case Jason.decode(source) do
      {:ok, %{} = config} ->
        unread_renovate(path, config, "") ++ constraint_problems(path, config, dockerfile_pins)

      {:ok, _other} ->
        ["#{path} is not a JSON object"]

      {:error, error} ->
        ["#{path} does not parse as JSON: #{Exception.message(error)}"]
    end
  end

  defp unread_renovate(path, %{} = map, location) do
    Enum.flat_map(map, fn {key, value} ->
      here = if location == "", do: key, else: "#{location}.#{key}"

      own =
        cond do
          key == "constraints" and location != "" ->
            [
              "#{path} #{here}: sets constraints below the top level, which this check cannot read"
            ]

          key == "extends" ->
            preset_problems(path, here, value)

          true ->
            []
        end

      own ++ unread_renovate(path, value, here)
    end)
  end

  defp unread_renovate(path, list, location) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      unread_renovate(path, value, "#{location}[#{index}]")
    end)
  end

  defp unread_renovate(_path, _scalar, _location), do: []

  defp preset_problems(path, here, presets) when is_list(presets) do
    for preset <- presets,
        preset not in @presets,
        do: "#{path} #{here}: names #{inspect(preset)}, whose constraints this check cannot read"
  end

  defp preset_problems(path, here, other),
    do: ["#{path} #{here}: is #{inspect(other)}, not a list"]

  defp constraint_problems(path, config, {dockerfile, pins}) do
    case Map.fetch(config, "constraints") do
      {:ok, %{} = constraints} ->
        for {tool, input} <- @constraints,
            {:ok, pin} <- [Map.fetch(pins, input)],
            problem <- constraint_problem(path, constraints, tool, pin, {dockerfile, input}),
            do: problem

      {:ok, other} ->
        ["#{path} constraints is #{inspect(other)}, not an object"]

      :error ->
        ["#{path} sets no constraints"]
    end
  end

  defp constraint_problem(path, constraints, tool, pin, {dockerfile, input}) do
    arg = "#{dockerfile}'s ARG #{@inputs[input]}"

    case {containerbase_name(tool, pin), Map.fetch(constraints, tool)} do
      {:error, _value} ->
        [
          ~s(#{path} constraints.#{tool}: #{arg} "#{pin}" has no containerbase build name ) <>
            "this check can derive"
        ]

      {{:ok, _name}, :error} ->
        ["#{path} constraints sets no #{tool}"]

      {{:ok, name}, {:ok, name}} ->
        []

      {{:ok, name}, {:ok, value}} ->
        build = if name == pin, do: "", else: ~s(, whose containerbase build is "#{name}")
        [~s(#{path} constraints.#{tool} #{inspect(value)}, but #{arg} is "#{pin}"#{build})]
    end
  end

  defp containerbase_name("erlang", otp) do
    cond do
      not Regex.match?(@containerbase_otp, otp) -> :error
      length(String.split(otp, ".")) == 3 -> {:ok, otp <> ".0"}
      true -> {:ok, otp}
    end
  end

  defp containerbase_name("elixir", elixir), do: {:ok, elixir}

  # The setup-beam steps of one workflow as `{where, %{input => version}}`, with a problem for each
  # input it cannot read.
  defp workflow_steps(path, source) do
    case YamlElixir.read_all_from_string(source) do
      {:ok, documents} ->
        {steps, problems} =
          documents
          |> Enum.flat_map(&walk(&1, ""))
          |> Enum.map(&finding(path, &1))
          |> Enum.unzip()

        {Enum.reject(steps, &is_nil/1), alias_problems(path, source) ++ Enum.concat(problems)}

      {:error, error} ->
        {[], ["#{path} does not parse as YAML: #{Exception.message(error)}"]}
    end
  end

  # Each setup-beam step in a parsed workflow, and each other mapping that sets one of its inputs,
  # with its location (jobs.test.steps[1]). A step's own with: mapping is not walked again.
  defp walk(%{} = map, location) do
    if is_binary(map["uses"]) and Regex.match?(@setup_beam, map["uses"]) do
      [{:step, location, map["with"]} | walk_values(Map.delete(map, "with"), location)]
    else
      stray =
        for {input, _arg} <- @inputs,
            Map.has_key?(map, input),
            do: {:stray, location, input, map[input]}

      stray ++ walk_values(map, location)
    end
  end

  defp walk(list, location) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> walk(value, "#{location}[#{index}]") end)
  end

  defp walk(_scalar, _location), do: []

  defp walk_values(map, location) do
    Enum.flat_map(map, fn {key, value} ->
      key = if is_binary(key), do: key, else: inspect(key)
      walk(value, if(location == "", do: key, else: "#{location}.#{key}"))
    end)
  end

  defp finding(path, {:stray, location, input, value}),
    do:
      {nil,
       ["#{path} #{location}: sets #{input} #{inspect(value)} outside an erlef/setup-beam step"]}

  defp finding(path, {:step, location, %{} = inputs}) do
    where = "#{path} #{location}"

    version_file =
      case Map.fetch(inputs, "version-file") do
        {:ok, file} ->
          ["#{where}: reads version-file #{inspect(file)}, which this check cannot read"]

        :error ->
          []
      end

    {values, problems} =
      @inputs |> Map.keys() |> Enum.map(&input_value(where, inputs, &1)) |> Enum.unzip()

    {{where, values |> Enum.concat() |> Map.new()}, version_file ++ Enum.concat(problems)}
  end

  defp finding(path, {:step, location, inputs}),
    do:
      {{"#{path} #{location}", %{}},
       ["#{path} #{location}: with: is #{inspect(inputs)}, not a mapping"]}

  defp input_value(where, inputs, input) do
    case Map.fetch(inputs, input) do
      {:ok, value} -> exact(input, value, "#{where}: #{input} is")
      :error -> {[], ["#{where}: sets no #{input}"]}
    end
  end

  # An unquoted 29.1 or 29 parses as a number, not a string, and fails here too.
  defp exact(input, value, subject) do
    if is_binary(value) and Regex.match?(@exact_version, value),
      do: {[{input, value}], []},
      else: {[], ["#{subject} #{inspect(value)}, not an exact major.minor.patch version"]}
  end

  # yamerl misreads an alias of a flow collection: *beam for `&beam {otp-version: "29.1.2"}` reads
  # as the string "otp-version", and an alias of a flow sequence as its first item. So a workflow
  # with an alias fails rather than being read wrong. The source already parsed, so yamerl is
  # started and the token scan raises no parse error.
  defp alias_problems(path, source) do
    me = self()
    ref = make_ref()

    :yamerl_parser.string(source,
      token_fun: fn token ->
        send(me, {ref, token})
        :ok
      end
    )

    for {:yamerl_alias, line, _column, name} <- drain_tokens(ref, []),
        do: "#{path}:#{line}: uses the YAML alias *#{name}, which this check cannot read"
  end

  defp drain_tokens(ref, tokens) do
    receive do
      {^ref, token} -> drain_tokens(ref, [token | tokens])
    after
      0 -> Enum.reverse(tokens)
    end
  end

  # The Dockerfile's default for each pinned ARG as `%{input => version}`, with a problem for each
  # ARG that has no default, more than one, or one that is not an exact version.
  defp dockerfile_pins(path, source) do
    {args, unread} = dockerfile_args(path, source)

    {pins, problems} = @inputs |> Enum.map(&arg_pin(path, args, &1)) |> Enum.unzip()
    {pins |> Enum.concat() |> Map.new(), unread ++ Enum.concat(problems)}
  end

  defp arg_pin(path, args, {input, arg}) do
    case for({^arg, value} <- args, value != nil, do: value) do
      [value] ->
        exact(input, value, "#{path}'s ARG #{arg} default is")

      [] ->
        {[], ["#{path} sets no default for ARG #{arg}"]}

      values ->
        defaults = Enum.map_join(values, " and ", &inspect/1)
        {[], ["#{path} sets #{length(values)} defaults for ARG #{arg}, #{defaults}, not one"]}
    end
  end

  # Every `{name, default}` the ARG instructions before the first FROM declare, in file order, with
  # a nil default for a bare `ARG NAME`. `FROM ${BUILDER_IMAGE}` resolves the builder tag from
  # those defaults alone, and Docker allows no instruction but ARG there, so no RUN, COPY or
  # heredoc can hide one. A stage's own ARG after FROM leaves that tag as it was. A line ending in
  # \ or ` there fails rather than being joined, so this reader needs neither Docker's
  # continuation rules nor the escape directive that changes them.
  defp dockerfile_args(path, source) do
    if String.valid?(source),
      do: preamble_args(path, source),
      else: {[], ["#{path} is not valid UTF-8, which this check cannot read"]}
  end

  # Docker skips a byte order mark, which would otherwise hide a FROM on the first line, and
  # strips every carriage return before a line feed. The u flag makes \s match the Unicode spaces
  # Docker trims before an instruction.
  defp preamble_args(path, source) do
    source
    |> String.trim_leading(<<0xFEFF::utf8>>)
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.with_index(1)
    |> Enum.take_while(fn {line, _number} -> not Regex.match?(~r/\A\s*FROM\s/iu, line) end)
    |> Enum.reject(fn {line, _number} -> String.trim(line) == "" or line =~ ~r/\A\s*#/u end)
    |> Enum.map(&preamble_line(path, &1))
    |> Enum.unzip()
    |> then(fn {args, problems} -> {Enum.concat(args), Enum.concat(problems)} end)
  end

  defp preamble_line(path, {line, number}) do
    case Regex.run(~r/([\\`])[ \t]*\z/, line, capture: :all_but_first) do
      [escape] ->
        {[],
         [
           "#{path}:#{number} continues onto the next line with #{escape}, which this check " <>
             "cannot read"
         ]}

      nil ->
        case Regex.run(~r/\A\s*ARG\s+(.*)\z/iu, line, capture: :all_but_first) do
          [declarations] -> {Enum.map(OptionParser.split(declarations), &arg_default/1), []}
          nil -> {[], []}
        end
    end
  end

  defp arg_default(declaration) do
    case String.split(declaration, "=", parts: 2) do
      [name, default] -> {name, default}
      [name] -> {name, nil}
    end
  end
end
