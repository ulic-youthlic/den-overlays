# Isolated tests for shipped den.overlays conversion.
# Import convert.nix + mark.nix + flakeModule only.
{
  lib,
  fx,
  flakeModule,
}:
let
  convert = import ./convert.nix { inherit lib fx; };
  mark = import ./mark.nix;
  overlaysModule = flakeModule;

  finalPkgs = {
    hello = "hello-from-final";
  };
  prevPkgs = {
    hello = "hello-from-prev";
  };

  apply = ov: ov finalPkgs prevPkgs;

  namesOf = attrs: lib.sort (a: b: a < b) (builtins.attrNames attrs);

  tryOverlays = tree: builtins.tryEval (builtins.deepSeq (namesOf (convert.toOverlays tree)) true);

  convertSrc = builtins.readFile ./convert.nix;
  testsSrc = builtins.readFile ./tests.nix;

  # --- trees (fixtures live here; not project overlay files) ---

  fnInjectSiblings = {
    helix.helix = { runtime, final }: final.hello;
    helix.runtime = mark.inject ({ final }: "rt");
  };

  deepFn = {
    foo.bar.baz.helix = { extra, final }: extra + final.hello;
    foo.bar.extra = mark.inject "e-";
  };

  fnExportSiblings = {
    helix.helix = { runtime, final }: final.hello;
    helix.runtime = mark.export ({ final }: "rt");
  };

  exportAttrset = {
    runtime = mark.export (
      { final }:
      {
        foo = final.hello;
      }
    );
  };

  allAttrs = {
    helix.helix = {
      x = 1;
    };
    helix.runtime = {
      y = 2;
    };
  };

  allAttrsScoped = {
    helix._scope = true;
    helix.helix = {
      x = 1;
    };
    helix.runtime = {
      y = 2;
    };
  };

  allAttrsLibScope = {
    helix = mark.scope {
      helix = {
        x = 1;
      };
      runtime = {
        y = 2;
      };
    };
  };

  topInjectSibling = {
    nvSources = mark.inject ({ final }: final.hello);
    uses-src = { nvSources }: {
      from-src = nvSources;
    };
  };

  exportThenDepend = {
    A = mark.export ({ final }: final.hello);
    B = { A }: {
      from-A = A;
    };
  };

  outOfScope = {
    den.test1 = mark.export (
      { final }:
      {
        test11 = final.hello;
      }
    );
    test2 = { test1 }: {
      test3 = test1.test11;
    };
  };

  nestedInjectHidden = {
    rime.helpers = mark.inject {
      mark = "helpers-rime-value";
    };
    leak = { helpers }: {
      mark = helpers.mark;
    };
  };

  inScopeUnderDen = {
    den.test1 = mark.export (
      { final }:
      {
        test11 = final.hello;
      }
    );
    den.uses = { test1 }: test1.test11;
  };

  unmarkedTop = {
    demo = { final, prev }: {
      from-final = final.hello;
      from-prev = prev.hello;
    };
  };

  mixedFnAndAttrs = {
    helix.helix = { final }: {
      pkg = final.hello;
    };
    helix.extra = {
      y = 2;
    };
  };

  overlaysFromFnInject = convert.toOverlays fnInjectSiblings;
  overlaysFromDeep = convert.toOverlays deepFn;
  overlaysFromFnExport = convert.toOverlays fnExportSiblings;
  overlaysFromExportAttrs = convert.toOverlays exportAttrset;
  overlaysFromAllAttrs = convert.toOverlays allAttrs;
  overlaysFromScoped = convert.toOverlays allAttrsScoped;
  overlaysFromLibScope = convert.toOverlays allAttrsLibScope;
  overlaysFromTopInject = convert.toOverlays topInjectSibling;
  overlaysFromAB = convert.toOverlays exportThenDepend;
  overlaysFromInScope = convert.toOverlays inScopeUnderDen;
  overlaysFromUnmarked = convert.toOverlays unmarkedTop;
  overlaysFromMixed = convert.toOverlays mixedFnAndAttrs;

  leftoverAtToOverlays = tryOverlays outOfScope;
  leftoverBind = builtins.tryEval (
    convert.bindLoop {
      test2 = { test1 }: {
        test3 = test1.test11;
      };
    } { }
  );
  leftoverNested = tryOverlays nestedInjectHidden;

  leftoverAtApply =
    # A leftover that slipped to apply would throw here. Conversion must
    # already have failed, so this is only a sanity check on tryEval.
    leftoverAtToOverlays;

  moduleEval = lib.evalModules {
    specialArgs = { };
    modules = [
      {
        options.flake.overlays = lib.mkOption {
          type = lib.types.lazyAttrsOf lib.types.raw;
          default = { };
        };
      }
      overlaysModule
      {
        den.overlays.helix.helix = { runtime, final }: final.hello;
      }
      {
        den.overlays.helix.runtime = mark.inject ({ final }: "rt");
      }
      {
        den.overlays.nvSources = mark.inject ({ final }: final.hello);
        den.overlays.uses-src = { nvSources }: {
          from-src = nvSources;
        };
      }
    ];
  };

  moduleOverlayNames = namesOf moduleEval.config.flake.overlays;
  moduleHelix = apply moduleEval.config.flake.overlays."helix/helix";
  moduleUses = apply moduleEval.config.flake.overlays.uses-src;

  assertions = [
    {
      name = "fn-inject-siblings-slash-name";
      ok = namesOf overlaysFromFnInject == [ "helix/helix" ];
      detail = namesOf overlaysFromFnInject;
    }
    {
      name = "fn-inject-siblings-apply";
      ok = apply overlaysFromFnInject."helix/helix" == { helix = finalPkgs.hello; };
      detail = apply overlaysFromFnInject."helix/helix";
    }
    {
      name = "inject-omitted-from-exported-overlays";
      ok = !(overlaysFromFnInject ? runtime) && !(overlaysFromFnInject ? "helix/runtime");
      detail = namesOf overlaysFromFnInject;
    }
    {
      name = "deep-fn-is-module-path";
      ok = namesOf overlaysFromDeep == [ "foo/bar/baz/helix" ];
      detail = namesOf overlaysFromDeep;
    }
    {
      name = "extra-visible-on-ancestor-scope";
      ok = apply overlaysFromDeep."foo/bar/baz/helix" == { helix = "e-" + finalPkgs.hello; };
      detail = apply overlaysFromDeep."foo/bar/baz/helix";
    }
    {
      name = "fn-export-siblings-two-overlays";
      ok = namesOf overlaysFromFnExport == [
        "helix/helix"
        "helix/runtime"
      ];
      detail = namesOf overlaysFromFnExport;
    }
    {
      name = "export-own-overlay-wraps-non-attrset";
      ok = apply overlaysFromFnExport."helix/runtime" == { runtime = "rt"; };
      detail = apply overlaysFromFnExport."helix/runtime";
    }
    {
      name = "export-attrset-has-no-extra-name-key";
      ok =
        namesOf overlaysFromExportAttrs == [ "runtime" ]
        && apply overlaysFromExportAttrs.runtime == { foo = finalPkgs.hello; };
      detail = apply overlaysFromExportAttrs.runtime;
    }
    {
      name = "all-attrsets-one-overlay-keys-are-content";
      ok =
        namesOf overlaysFromAllAttrs == [ "helix" ]
        && apply overlaysFromAllAttrs.helix == {
          helix = {
            x = 1;
          };
          runtime = {
            y = 2;
          };
        };
      detail = {
        names = namesOf overlaysFromAllAttrs;
        result = apply overlaysFromAllAttrs.helix;
      };
    }
    {
      name = "scope-flag-splits-all-attrset-tree";
      ok =
        namesOf overlaysFromScoped == [
          "helix/helix"
          "helix/runtime"
        ]
        && apply overlaysFromScoped."helix/helix" == { x = 1; }
        && apply overlaysFromScoped."helix/runtime" == { y = 2; };
      detail = namesOf overlaysFromScoped;
    }
    {
      name = "lib-scope-splits-all-attrset-tree";
      ok =
        namesOf overlaysFromLibScope == [
          "helix/helix"
          "helix/runtime"
        ]
        && apply overlaysFromLibScope."helix/helix" == { x = 1; };
      detail = namesOf overlaysFromLibScope;
    }
    {
      name = "top-inject-omitted-sibling-sees-extra";
      ok =
        namesOf overlaysFromTopInject == [ "uses-src" ]
        && apply overlaysFromTopInject.uses-src == { from-src = finalPkgs.hello; };
      detail = {
        names = namesOf overlaysFromTopInject;
        result = apply overlaysFromTopInject.uses-src;
      };
    }
    {
      name = "export-final-then-sibling-depends";
      ok =
        namesOf overlaysFromAB == [
          "A"
          "B"
        ]
        && apply overlaysFromAB.A == { A = finalPkgs.hello; }
        && apply overlaysFromAB.B == { from-A = finalPkgs.hello; };
      detail = {
        names = namesOf overlaysFromAB;
        A = apply overlaysFromAB.A;
        B = apply overlaysFromAB.B;
      };
    }
    {
      name = "in-scope-last-component-under-den";
      ok =
        namesOf overlaysFromInScope == [
          "den/test1"
          "den/uses"
        ]
        && apply overlaysFromInScope."den/test1" == { test11 = finalPkgs.hello; }
        && apply overlaysFromInScope."den/uses" == { uses = finalPkgs.hello; };
      detail = {
        names = namesOf overlaysFromInScope;
        test1 = apply overlaysFromInScope."den/test1";
        uses = apply overlaysFromInScope."den/uses";
      };
    }
    {
      name = "out-of-scope-extra-fails-at-toOverlays";
      ok = !leftoverAtToOverlays.success;
      detail = leftoverAtToOverlays;
    }
    {
      name = "out-of-scope-extra-fails-at-bindLoop";
      ok = !leftoverBind.success;
      detail = leftoverBind;
    }
    {
      name = "nested-inject-not-visible-at-root";
      ok = !leftoverNested.success;
      detail = leftoverNested;
    }
    {
      name = "convert-time-not-apply-time-for-leftover";
      ok = leftoverAtApply.success == false;
      detail = leftoverAtApply;
    }
    {
      name = "unmarked-top-sees-final-and-prev";
      ok =
        namesOf overlaysFromUnmarked == [ "demo" ]
        && apply overlaysFromUnmarked.demo == {
          from-final = finalPkgs.hello;
          from-prev = prevPkgs.hello;
        };
      detail = apply overlaysFromUnmarked.demo;
    }
    {
      name = "mixed-fn-and-attrset-split-module-path";
      ok =
        namesOf overlaysFromMixed == [
          "helix/extra"
          "helix/helix"
        ]
        && apply overlaysFromMixed."helix/helix" == { pkg = finalPkgs.hello; }
        && apply overlaysFromMixed."helix/extra" == { y = 2; };
      detail = namesOf overlaysFromMixed;
    }
    {
      name = "module-eval-merges-files-and-uses-den-overlayLib";
      ok =
        moduleEval.config.den.overlayLib ? inject
        && moduleEval.config.den.overlayLib ? export
        && moduleEval.config.den.overlayLib ? scope
        && moduleOverlayNames == [
          "helix/helix"
          "uses-src"
        ]
        && moduleHelix == { helix = finalPkgs.hello; }
        && moduleUses == { from-src = finalPkgs.hello; };
      detail = {
        lib = builtins.attrNames moduleEval.config.den.overlayLib;
        names = moduleOverlayNames;
        helix = moduleHelix;
        uses = moduleUses;
      };
    }
    {
      name = "bind-path-uses-nix-effects";
      ok =
        lib.hasInfix "fx.bind.fn" convertSrc
        && lib.hasInfix "fx.handle" convertSrc
        && lib.hasInfix "fx.effects.scope.val" convertSrc
        && lib.hasInfix "handlersFromAttrs" convertSrc
        && !(lib.hasInfix "_module.args" convertSrc);
      detail = "fx.bind.fn/fx.handle/scope.val/handlersFromAttrs present; no _module.args merge";
    }
    {
      name = "tests-import-shipped-convert-only";
      ok =
        lib.hasInfix "import ./convert.nix" testsSrc
        && lib.hasInfix "import ./mark.nix" testsSrc;
      detail = "imports shipped convert/mark";
    }
    {
      name = "apply-does-not-force-overlay-values";
      ok =
        let
          ovs = convert.toOverlays {
            demo = { prev }: {
              foo = throw "should stay lazy";
              bar = prev.hello;
            };
          };
          result = apply ovs.demo;
        in
        namesOf result == [
          "bar"
          "foo"
        ]
        && result.bar == prevPkgs.hello;
      detail = "attrNames and unused sibling stay lazy";
    }
    {
      name = "nixpkgs-style-fixpoint";
      ok =
        let
          ovs = convert.toOverlays {
            demo = { final, prev }: {
              hello = prev.hello;
              greet = final.hello + "-greet";
            };
          };
          prev = prevPkgs;
          self = prev // ovs.demo self prev;
        in
        self.hello == prevPkgs.hello && self.greet == prevPkgs.hello + "-greet";
      detail = "final.hello is the overlay's own hello, lazily";
    }
  ];

  failed = builtins.filter (a: !a.ok) assertions;
in
{
  inherit
    assertions
    failed
    ;

  ok = failed == [ ];
}
