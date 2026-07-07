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
      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          # Pin Elixir + OTP from one beam set so Elixir is built against exactly
          # this OTP, matching CI (.github/workflows/ci.yml: OTP 29 / Elixir 1.20).
          # The bare `beamPackages.elixir` floated to the nixpkgs default (1.18.x),
          # which won't compile this project. If `nix develop` reports
          # `attribute 'elixir_1_20' missing`, the locked nixpkgs predates the 1.20
          # packaging — run `nix flake update`, or fall back to the known-good
          # baseline: `beam = pkgs.beam.packages.erlang_28; elixir = beam.elixir_1_19;`.
          beam = pkgs.beam.packages.erlang_29;
          elixir = beam.elixir_1_20;
        in
        {
          default = pkgs.mkShell {
            # `elixir` wraps mix/iex to find its OTP internally, so erlang is not
            # listed separately. mkShell's stdenv already provides cc + make for
            # exqlite/bcrypt_elixir's C NIFs; hex + rebar come from ~/.mix as usual
            # (run `mix local.hex` / `mix local.rebar` once on a fresh machine).
            # git is needed at `mix deps.get` (heroicons is a github: dep);
            # inotify-tools drives Phoenix live-reload on Linux (macOS uses fs_events).
            packages = [
              elixir
              pkgs.git
            ]
            ++ pkgs.lib.optional pkgs.stdenv.isLinux pkgs.inotify-tools;

            # C.UTF-8 silences Erlang's latin1 locale warning without a glibcLocales
            # archive (glibc ships C.UTF-8 built in).
            shellHook = ''
              export LANG=C.UTF-8
              export LC_ALL=C.UTF-8
            '';
          };
        }
      );

      # `nix fmt <file>` formats this flake with nixfmt (the RFC 166 style).
      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
