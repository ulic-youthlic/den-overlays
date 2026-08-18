# den-overlays

flake-parts module that turns a `den.overlays` tree into ordinary
`flake.overlays`. Nested extras use nix-effects scoped injection (`inject` /
`export`); unmarked functions are overlay content.

Part of the [den](https://github.com/denful/den) ecosystem.

## Use from another flake

```nix
{
  inputs.den-overlays.url = "path:/absolute/or/github:you/den-overlays";

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.den-overlays.flakeModules.default ];
      # den.overlays.foo = { final, prev }: { … };
    };
}
```

`nix-effects` is an input of this flake and is closed over by
`flakeModules.default`. Consumers do not add `nix-effects` themselves.

Convert tests run as `nix flake check` on this flake
(`checks.<system>.den-overlays-convert`).

In overlay modules, markers are available as `den.overlayLib` or as
`denOverlay.lib` (a `_module.args` alias so they do not collide with
den's `den.lib`).

## API

Markers live on `den.overlayLib` so they do not collide with den's `den.lib`.

- `den.overlayLib.inject value` — extra, in scope for descendants, not exported
- `den.overlayLib.export value` — extra, in scope, exported as its own overlay
- `den.overlayLib.scope attrs` — `_scope = true`; only needed when every leaf is a plain attrset
- `den.overlays.<path>` — module path when the leaf is a function / inject / export

Refer to an extra by its **last path component** as a function argument.
`final`, `prev`, `lib`, `config`, and the other reserved module args are
always available; extras that name them are deferred and resolved when
the overlay is applied.

Apply an exported overlay as `overlay pkgs pkgs` (or `overlay final prev`).
Do not use `pkgs.extend` / `appendOverlays` if you only want the overlay's
return value: that re-enters nixpkgs and can recurse through `final`.

## Examples

### Unmarked overlay

A function or attrset that is not `inject`/`export` becomes one overlay
named after its path. It can see `final` and `prev`, but nothing can
depend on it as an extra.

```nix
{
  den.overlays.nautilus = { prev }: {
    nautilus = prev.nautilus.overrideAttrs (old: {
      buildInputs = (old.buildInputs or [ ]) ++ [ prev.gst_all_1.gst-plugins-good ];
    });
  };
}
```

Yields `flake.overlays.nautilus`. Applied, that overlay returns
`{ nautilus = <drv>; }`.

Forwarding another flake's overlay is the same shape:

```nix
{ inputs, ... }:
{
  den.overlays.niri = { final, prev }:
    inputs.niri.overlays.default final prev;
}
```

### Inject: share a value without exporting it

`inject` is visible to siblings and descendants on the same scope, and is
omitted from `flake.overlays`.

```nix
{ denOverlay, ... }:
{
  den.overlays.nvSources = denOverlay.lib.inject (
    { final }: final.callPackage ./_sources/generated.nix { }
  );

  den.overlays.TrackersListCollection = { nvSources }: {
    TrackersListCollection = nvSources.TrackersListCollection.src;
  };
}
```

Yields only `flake.overlays.TrackersListCollection`. `nvSources` is not
an overlay; `TrackersListCollection` receives the injected attrset.

### Function + inject under one path

A function, `inject`, or `export` makes its path a **module path**.
Ancestors become scopes. No `_scope` is required.

```nix
{ denOverlay, ... }:
{
  # overlays/helix/default.nix
  den.overlays.helix.helix = { runtime, final, prev }:
    let
      helix = (inputs.helix.overlays.helix final prev).helix;
    in
    helix.overrideAttrs (_: old: {
      env.HELIX_DEFAULT_RUNTIME = toString runtime;
    });
}
```

```nix
{ denOverlay, ... }:
{
  # overlays/helix/runtime.nix  (merges with the file above)
  den.overlays.helix.runtime = denOverlay.lib.inject (
    { final }: final.runCommand "helix-runtime" { } "mkdir $out"
  );
}
```

Yields `flake.overlays."helix/helix"` only. `runtime` is in scope for
`helix`. Applied, the overlay wraps a non-attrset result as
`{ helix = <drv>; }` so nixpkgs still gets an attrset.

Different files may assign `helix.helix` and `helix.runtime`; nested
attrsets merge. Two files must not assign the same leaf.

### Export: share a value and ship it as an overlay

`export` is injectable **and** becomes its own overlay.

```nix
{ denOverlay, ... }:
{
  den.overlays.A = denOverlay.lib.export ({ final }: final.hello);
  den.overlays.B = { A }: { from-A = A; };
}
```

Yields `flake.overlays.A` and `flake.overlays.B`.

- `A` applied → `{ A = <hello>; }` (non-attrset export wrapped under the leaf name)
- `B` applied → `{ from-A = <hello>; }`

If the export is already an attrset, that attrset **is** the overlay
content. The extra name is not inserted as a key:

```nix
{ denOverlay, ... }:
{
  den.overlays.runtime = denOverlay.lib.export ({ final }: {
    foo = final.hello;
  });
}
```

Yields `flake.overlays.runtime` → `{ foo = <hello>; }`, not
`{ runtime = { foo = …; }; }`.

Do not mix a bare derivation export with sibling attrset content in the
same overlay; the converter refuses `{ name = drv }` vs a raw drv.

### Deep module paths

```nix
{ denOverlay, ... }:
{
  den.overlays.foo.bar.extra = denOverlay.lib.inject "e-";
  den.overlays.foo.bar.baz.helix = { extra, final }: extra + final.hello.name;
}
```

Yields `flake.overlays."foo/bar/baz/helix"`. `extra` is visible because
it is declared on an ancestor scope (`foo.bar`).

### All attrsets: one overlay, keys are content

If every leaf is a plain attrset (no function / inject / export), the
path is **not** split. Nested keys become the overlay result.

```nix
{
  den.overlays.helix.helix = { x = 1; };
  den.overlays.helix.runtime = { y = 2; };
}
```

Yields one overlay `flake.overlays.helix` →
`{ helix = { x = 1; }; runtime = { y = 2; }; }`.

### Split an all-attrset tree with `_scope`

Use `_scope = true` or `den.overlayLib.scope` only when you still want
slash-names but every leaf is a plain attrset.

```nix
{
  den.overlays.helix._scope = true;
  den.overlays.helix.helix = { x = 1; };
  den.overlays.helix.runtime = { y = 2; };
}
```

or

```nix
{ denOverlay, ... }:
{
  den.overlays.helix = denOverlay.lib.scope {
    helix = { x = 1; };
    runtime = { y = 2; };
  };
}
```

Yields `flake.overlays."helix/helix"` → `{ x = 1; }` and
`flake.overlays."helix/runtime"` → `{ y = 2; }`.

A mix of a function and a sibling attrset also splits (the function
implies a module path):

```nix
{
  den.overlays.helix.helix = { final }: { pkg = final.hello; };
  den.overlays.helix.extra = { y = 2; };
}
```

Yields `helix/helix` and `helix/extra`.

### Extra names are the last component only

```nix
{ denOverlay, ... }:
{
  den.overlays.group.test1 = denOverlay.lib.export ({ final }: {
    test11 = final.hello;
  });
  den.overlays.group.uses = { test1 }: test1.test11;
}
```

Yields `group/test1` and `group/uses`. Dependents ask for `test1`, not
`group.test1`.

An extra is visible on the declaring scope and its descendants. A
sibling **outside** that scope cannot see it — conversion throws, it
does not wait until apply:

```nix
{ denOverlay, ... }:
{
  den.overlays.group.test1 = denOverlay.lib.export ({ final }: {
    test11 = final.hello;
  });
  # error at convert: extra `test1` not in this scope
  den.overlays.test2 = { test1 }: { test3 = test1.test11; };
}
```

The same happens if you inject under `rime.helpers` and try to take
`helpers` on a root overlay: `helpers` is not in the root scope.

### Files that only assign overlays

Keep one overlay (or one scope) per file and let import-tree load them.
Markers come from `denOverlay`, not from den's host library:

```nix
# overlays/pinentry-selector.nix
{
  den.overlays.pinentry-selector = { final }: {
    pinentry-selector = final.writeShellApplication {
      name = "pinentry";
      text = "exec pinentry-tty \"$@\"";
    };
  };
}
```

```nix
# overlays/wshowkeys-mao.nix
{
  den.overlays.wshowkeys-mao = { nvSources, final }: {
    wshowkeys = final.wshowkeys.overrideAttrs {
      inherit (nvSources.wshowkeys-mao) src;
    };
  };
}
```

`nvSources` works here because the inject lives on the root scope (see
above), so every overlay can name it.

## What `flake.overlays` looks like

After conversion you get a normal flake-parts `flake.overlays` attrset:
names are `/`-joined module paths, values are `final: prev: attrs`.

```nix
# names from a typical consumer
[
  "OuterWildsTextAdventure"
  "TrackersListCollection"
  "helix/helix"          # inject runtime is omitted
  "iosevka-serif_fixed"
  "niri"
  "pinentry-selector"
  # …
]
```

Use them like any other overlay:

```nix
pkgs.appendOverlays [
  inputs.self.overlays.niri
  inputs.self.overlays."helix/helix"
]
```

or inspect only what one overlay adds:

```nix
let
  overlay = inputs.self.overlays.pinentry-selector;
in
  overlay pkgs pkgs
# => { pinentry-selector = <drv>; }
```
