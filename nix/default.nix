{
  flakeModules.default = ./flakeModule.nix;
  flakeModule = ./flakeModule.nix;
  lib = {
    convert = ./lib/convert.nix;
    mark = ./lib/mark.nix;
    realize = ./lib/realize.nix;
    tests = ./lib/tests.nix;
  };
}
