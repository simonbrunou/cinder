{
  description = "cinder dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # x86_64-linux is CI; aarch64-darwin is the dev laptop.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          # Pin Elixir + OTP from one beam set so Elixir is built against exactly
          # this OTP, matching CI (.forgejo/workflows/ci.yml: OTP 29 / Elixir 1.20).
          # The bare `beamPackages.elixir` floated to the nixpkgs default (1.18.x),
          # which won't compile this project. If `nix develop` reports
          # `attribute 'elixir_1_20' missing`, the locked nixpkgs predates the 1.20
          # packaging — run `nix flake update`, or fall back to the known-good
          # baseline: `beam = pkgs.beam.packages.erlang_28; elixir = beam.elixir_1_19;`.
          beam = pkgs.beam.packages.erlang_29;
          elixir = beam.elixir_1_20;
          # A python3 that can import ffsubsync, so `python3 priv/ffsubsync_runner.py ...` runs the
          # subtitle sync engine with no venv. nixpkgs packages ffsubsync as an application built
          # with `python3.pkgs`, hence `toPythonModule`. Keep it on the Dockerfile's pin
          # (`ffsubsync==0.5.1`); after a lock bump, check the version with
          # `nix eval --raw --inputs-from . nixpkgs#ffsubsync.version`.
          python = pkgs.python3.withPackages (ps: [ (ps.toPythonModule pkgs.ffsubsync) ]);
          # Tailwind from a Nix fetch, so `mix assets.setup` never downloads it with Erlang's
          # :httpc, which can fail on GitHub's release redirect (#889, docs/agents/ci.md
          # "Dependency rebuild"). shellHook points MIX_TAILWIND_PATH at it, which
          # `config :tailwind, path:` reads. tailwindVersion must equal `config :tailwind, version:`
          # (test/code_health_test.exs checks it): on a mismatch `tailwind.install --if-missing`
          # downloads the configured version and cannot write it into the read-only store. It is
          # pinned here, not left at nixpkgs' tailwindcss_4 version, since following that would
          # move `config :tailwind, version:`, and with it the Tailwind the image ships, on every
          # nixpkgs bump. The sums come from the release's sha256sums.txt.
          tailwindVersion = "4.1.12";
          tailwindRelease =
            {
              x86_64-linux = {
                target = "linux-x64";
                sha256 = "5eeee66ea237eae9a160fa3314fd0cf76ab993551a99fafb16fa1db6c6b90289";
              };
              aarch64-darwin = {
                target = "macos-arm64";
                sha256 = "7d69be1776bbe8a49e15714d9873d08959c320aff0f0714d8d8e6d9d00d9b543";
              };
            }
            .${pkgs.stdenv.hostPlatform.system};
          # nixpkgs' derivation makes the release binary run here (autoPatchelfHook on Linux, a
          # wrapper that adds libstdc++ to LD_LIBRARY_PATH) and checks that `--help` prints its
          # version; only the version and the source change.
          tailwindcss = pkgs.tailwindcss_4.overrideAttrs {
            version = tailwindVersion;
            src = pkgs.fetchurl {
              url = "https://github.com/tailwindlabs/tailwindcss/releases/download/v${tailwindVersion}/tailwindcss-${tailwindRelease.target}";
              inherit (tailwindRelease) sha256;
            };
          };
        in
        {
          default = pkgs.mkShell {
            # `elixir` wraps mix/iex to find its OTP internally, so erlang is not
            # listed separately. mkShell's stdenv already provides cc + make for
            # exqlite/bcrypt_elixir's C NIFs; hex + rebar come from ~/.mix as usual
            # (run `mix local.hex` / `mix local.rebar` once on a fresh machine).
            # git is needed at `mix deps.get` (heroicons is a github: dep);
            # inotify-tools drives Phoenix live-reload on Linux (macOS uses fs_events).
            # cmake builds lazy_html's NIF from source (lexbor) when elixir_make cannot download
            # the precompiled one, which fails the same :httpc way as Tailwind (#889).
            packages = [
              elixir
              pkgs.git
              pkgs.cmake
              python
              tailwindcss
            ]
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.inotify-tools;

            # C.UTF-8 silences Erlang's latin1 locale warning without a glibcLocales
            # archive (glibc ships C.UTF-8 built in).
            shellHook = ''
              export LANG=C.UTF-8
              export LC_ALL=C.UTF-8
              export MIX_TAILWIND_PATH=${tailwindcss}/bin/tailwindcss
            '';
          };
        }
      );

      # `nix fmt <file>` formats this flake with nixfmt (the RFC 166 style).
      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
