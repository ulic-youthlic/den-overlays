# flake-parts module: `den.overlays` → `flake.overlays`.
#
# Bind `fx` when importing so the consumer need not expose `nix-effects`:
#   import ./flakeModule.nix { inherit fx; }
#
# Markers live on `den.overlayLib` so they do not collide with den's
# existing `den.lib` (hosts, schema, fx, …).
{ fx }:
{
  lib,
  config,
  ...
}:
let
  convert = import ./lib/convert.nix { inherit lib fx; };
  overlayLib = import ./lib/mark.nix;

  # Nested attrsets from different files merge. Leaves (functions,
  # inject/export markers, thunks, non-attrs) stay unique.
  isMergeableScope =
    v: builtins.isAttrs v && !lib.isFunction v && !overlayLib.isMarked v && !overlayLib.isThunk v;

  overlayTree = lib.mkOptionType {
    name = "denOverlayTree";
    description = "overlay tree (nested attrset of inject/export/overlay values)";
    check = _: true;
    merge =
      loc: defs:
      if builtins.all (d: isMergeableScope d.value) defs then
        let
          names = lib.unique (lib.concatMap (d: builtins.attrNames (removeAttrs d.value [ "_scope" ])) defs);
          declared = builtins.any (d: (d.value._scope or false) == true) defs;
          merged = lib.genAttrs names (
            name:
            overlayTree.merge (loc ++ [ name ]) (
              lib.concatMap (
                d:
                if d.value ? ${name} then
                  [
                    {
                      inherit (d) file;
                      value = d.value.${name};
                    }
                  ]
                else
                  [ ]
              ) defs
            )
          );
        in
        merged // lib.optionalAttrs declared { _scope = true; }
      else if builtins.length defs == 1 then
        (builtins.head defs).value
      else
        throw "The option `${lib.showOption loc}' is defined multiple times while it's expected to be unique.\nNested overlay trees merge only when every definition is an attribute set (not a function and not inject/export).\nDefinition values:${
          lib.concatMapStrings (
            d: "\n- In `${toString d.file}': ${lib.generators.toPretty { multiline = false; } d.value}"
          ) defs
        }";
  };
in
{
  options.den.overlayLib = lib.mkOption {
    type = lib.types.raw;
    readOnly = true;
    default = overlayLib;
    description = ''
      Overlay-tree markers (not `den.lib`, which is den's core library):
      - `inject value` — resolved extra, visible to descendant scopes, not exported
      - `export value` — resolved extra, visible to descendant scopes, exported
      - `scope attrs` — mark this attrset as a scope (`_scope = true`)
      Unmarked overlay functions/attrs are exported and are not extras.
    '';
  };

  options.den.overlays = lib.mkOption {
    # Custom tree type so `helix.helix` and `helix.runtime` from
    # different files merge. Markers stay raw (not coerced to modules).
    type = overlayTree;
    default = { };
    description = ''
      Attrset of overlay modules. Mark resolved extras with
      `den.overlayLib.inject` (scope-only) or `den.overlayLib.export`
      (scope + overlay). Unmarked content is a normal overlay.

      A function, `inject`, or `export` makes its path a module path:
      ancestors become scopes, and that leaf is an overlay (or an extra).
      `_scope = true` / `den.overlayLib.scope` is only needed when every
      leaf is a plain attrset and you still want to split the path.

        den.overlays.helix.helix = { runtime, final, prev }: drv;
        den.overlays.helix.runtime = den.overlayLib.inject (…);
      yields `flake.overlays."helix/helix"`; `runtime` is in scope for
      `helix`. No `_scope` required.

        den.overlays.foo.bar.baz.helix = { final }: drv;
      yields `flake.overlays."foo/bar/baz/helix"`.

      All attrsets, no `_scope`:
        den.overlays.helix.helix = { … };
        den.overlays.helix.runtime = { … };
      yields one overlay `flake.overlays.helix` =
      `{ helix = { … }; runtime = { … }; }`.

      All attrsets, with `_scope` on helix:
        den.overlays.helix._scope = true;
        den.overlays.helix.helix = { … };
      yields `flake.overlays."helix/helix"`.

      Inject extras stay in scope and are omitted from flake.overlays.
      Export extras are their own overlay (`helix/runtime`).

      Refer to an extra by its last path component as a function arg.
      Extras on a scope ancestor (or the root) are visible to
      descendants. Out-of-scope extras fail at conversion.

      Extras that name `final`/`prev`/`config` are deferred like den
      config-thunks and resolved inside evalModules. Binding still
      uses nix-effects, not module-system args.
    '';
  };

  config._module.args.denOverlay = {
    lib = config.den.overlayLib;
  };

  config.flake.overlays = convert config.den.overlays;
}
