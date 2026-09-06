{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-26.05;
  };

  outputs = {self, nixpkgs, ...}: let 
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in  {
    devShells.x86_64-linux = {
      default = pkgs.mkShell {
        packages = with pkgs; [ zig zon2nix ];
      };
    };

    packages.x86_64-linux = rec {
      default = zig-xml;

      zig-xml = pkgs.stdenv.mkDerivation {
        pname = "zig-xml";
        version = "0.0.1";

        src = ./.;

        nativeBuildInputs = with pkgs; [zig];
      };
    };
  };
}