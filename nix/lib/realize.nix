# Apply a nixpkgs overlay to real pkgs and collect its *return value*
# (not the whole package set). Top-level derivations are kept for
# building; other values are summarized so checks still force apply.
{ lib }:
let
  isDrv = v: lib.isDerivation v;

  summarize =
    v:
    if isDrv v then
      {
        kind = "derivation";
        name = v.name or v.pname or "<drv>";
      }
    else if builtins.isPath v || (builtins.isString v && builtins.substring 0 1 v == "/") then
      {
        kind = "path";
        value = toString v;
      }
    else if builtins.isString v then
      {
        kind = "string";
        value = v;
      }
    else if builtins.isInt v || builtins.isFloat v || builtins.isBool v then
      {
        kind = "scalar";
        value = v;
      }
    else if builtins.isList v then
      {
        kind = "list";
        length = builtins.length v;
      }
    else if lib.isFunction v then
      {
        kind = "function";
      }
    else if builtins.isAttrs v then
      {
        kind = "attrs";
        names = lib.sort (a: b: a < b) (builtins.attrNames v);
      }
    else
      {
        kind = "other";
        type = builtins.typeOf v;
      };

  # Overlay content is usually a small attrset of packages. Do not walk
  # nested package sets (nur, linuxPackages, …).
  collect =
    result:
    if isDrv result then
      {
        derivations = {
          result = result;
        };
        other = { };
      }
    else if !(builtins.isAttrs result) || lib.isFunction result then
      {
        derivations = { };
        other = {
          result = summarize result;
        };
      }
    else
      lib.foldlAttrs (
        acc: name: value:
        if isDrv value then
          acc
          // {
            derivations = acc.derivations // {
              ${name} = value;
            };
          }
        else
          acc
          // {
            other = acc.other // {
              ${name} = summarize value;
            };
          }
      ) { derivations = { }; other = { }; } result;

  # Use the same pkgs for `final` and `prev` so this helper only sees
  # the overlay *return value*, not a nixpkgs fixpoint. Overlay apply
  # itself is lazy: `import nixpkgs { overlays = [ ov ]; }` is the
  # supported way to get a full package set.
  applyOverlay =
    pkgs: overlay:
    let
      result = overlay pkgs pkgs;
      collected = collect result;
    in
    collected
    // {
      inherit result;
      names =
        if builtins.isAttrs result && !lib.isFunction result && !isDrv result then
          lib.sort (a: b: a < b) (builtins.attrNames result)
        else
          [ "result" ];
    };
in
{
  inherit
    isDrv
    summarize
    collect
    applyOverlay
    ;
}
