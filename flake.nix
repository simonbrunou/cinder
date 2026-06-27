{
  description = "cinder dev shell";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";  # ponytail: single machine; add flake-utils for multi-arch
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        # beamPackages.* (not the deprecated top-level elixir/erlang aliases);
        # inotify-tools is required by Phoenix live-reload on Linux.
        packages = with pkgs; [ beamPackages.elixir beamPackages.erlang inotify-tools ];
      };
    };
}
