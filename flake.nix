{
  description = "SOMig - a Zig VM for the SOM language.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs:
        {
          default = pkgs.mkShell {
            name = "SOMig";
            packages = [ pkgs.zig_0_15 pkgs.zls_0_15 pkgs.pkg-config ];
          };
        });
    };
}
