{
  description = "LordMZTE's river window manager";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self
    , nixpkgs
    , utils
    }: utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
      mzterwm = pkgs.callPackage ./package.nix { };
    in
    {
      packages.default = mzterwm;
      packages.mzterwm = mzterwm;
      devShells.default = pkgs.mkShell {
        buildInputs = mzterwm.buildInputs ++ (with pkgs; [
          zig_0_15
          pkg-config
        ]);
      };
      overlays.default = final: prev: {
        mzterwm = final.callPackage ./package.nix { };
      };
    });
}

