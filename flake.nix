{
  description = "cinder dev shell";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";  # ponytail: single machine; add flake-utils for multi-arch
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = with pkgs; [ elixir erlang ];
      };
    };
}
