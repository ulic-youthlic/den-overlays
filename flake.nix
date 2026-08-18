{
  description = "den.overlays: flake-parts overlay trees with scoped inject/export";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nix-effects = {
      url = "github:denful/nix-effects";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nix-effects,
      ...
    }:
    let
      fx = nix-effects.lib;
      flakeModule = import ./nix/flakeModule.nix { inherit fx; };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ flakeModule ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      flake = {
        flakeModules.default = flakeModule;
        inherit flakeModule;
        lib = {
          inherit fx;
          convert = ./nix/lib/convert.nix;
          mark = ./nix/lib/mark.nix;
          realize = ./nix/lib/realize.nix;
          tests = ./nix/lib/tests.nix;
        };
      };
      perSystem =
        { pkgs, lib, ... }:
        let
          unit = import ./nix/lib/tests.nix {
            inherit lib fx flakeModule;
          };
          report = builtins.toJSON {
            inherit (unit) ok;
            failed = map (a: a.name) unit.failed;
            cases = map (a: a.name) unit.assertions;
          };
        in
        {
          checks.den-overlays-convert =
            pkgs.runCommand "den-overlays-convert"
              {
                passAsFile = [ "report" ];
                inherit report;
              }
              ''
                set -eu
                if [ "${if unit.ok then "ok" else "fail"}" != ok ]; then
                  echo "den.overlays convert tests failed" >&2
                  cat "$reportPath" >&2
                  exit 1
                fi
                mkdir -p "$out"
                cp "$reportPath" "$out/report.json"
              '';
        };
    };
}
