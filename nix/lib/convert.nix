# Convert `den.overlays` module trees into ordinary nixpkgs overlays.
#
# Walk each overlay module: collect parameterised functions and scope
# handlers, bind with nix-effects (`fx.bind.fn` + `fx.handle` +
# `fx.effects.scope.val`), repeat until no unbound extras remain, then
# `evalModules` the bound modules. Extra values are never passed as
# specialArgs or module-system args.
#
# Resolved extras may name reserved overlay args (`final`, `prev`, `lib`,
# `config`, …). Those are deferred (den-style) and applied inside
# evalModules, then substituted into dependents.
{ lib, fx }:
let
  mark = import ./mark.nix;

  reservedArgs = {
    lib = true;
    config = true;
    options = true;
    pkgs = true;
    modulesPath = true;
    specialArgs = true;
    final = true;
    prev = true;
  };

  reservedKeys = {
    _file = true;
    key = true;
    disabledModules = true;
    freeformType = true;
    _module = true;
  };

  functionArgsOf = f: if lib.isFunction f then lib.functionArgs f else { };

  extraArgNames =
    f:
    builtins.filter (n: !(reservedArgs ? ${n})) (builtins.attrNames (functionArgsOf f));

  reservedArgNames =
    f: builtins.filter (n: reservedArgs ? ${n}) (builtins.attrNames (functionArgsOf f));

  takesReserved = f: reservedArgNames f != [ ];

  isParametric = f: lib.isFunction f && extraArgNames f != [ ];

  isValueFn = f: lib.isFunction f && (extraArgNames f != [ ] || takesReserved f);

  dummyModuleArgs = {
    inherit lib;
    config = { };
    options = { };
    pkgs = { };
    modulesPath = "";
    specialArgs = { };
    final = { };
    prev = { };
  };

  applyReserved =
    fn:
    let
      args = functionArgsOf fn;
      supplied = if args == { } then dummyModuleArgs else lib.intersectAttrs args dummyModuleArgs;
    in
    fn supplied;

  hasWork =
    v:
    if mark.isMarked v then
      true
    else if mark.isThunk v then
      true
    else if isParametric v then
      true
    else if lib.isFunction v then
      true
    else if builtins.isAttrs v && !lib.isFunction v then
      let
        keys = builtins.attrNames (removeAttrs v (builtins.attrNames reservedKeys));
      in
      builtins.any (
        k:
        if k == "imports" then
          builtins.any hasWork (lib.toList v.imports)
        else if k == "options" then
          false
        else if k == "config" then
          hasWork v.config
        else
          hasWork v.${k}
      ) keys
    else
      false;

  handlersFrom = attrs: fx.effects.scope.handlersFromAttrs attrs;

  resolveThunk =
    modArgs: v:
    if mark.isThunk v then
      let
        args = functionArgsOf v.__fn;
        supplied = if args == { } then modArgs else lib.intersectAttrs args (modArgs // { inherit lib; });
      in
      resolveDeep modArgs (v.__fn supplied)
    else
      v;

  resolveDeep =
    modArgs: v:
    let
      r = resolveThunk modArgs v;
    in
    if builtins.isList r then
      map (resolveDeep modArgs) r
    else if mark.isMarked r then
      mark.remake r (resolveDeep modArgs r.value)
    else if builtins.isAttrs r && !lib.isFunction r && !mark.isThunk r then
      lib.mapAttrs (_: resolveDeep modArgs) r
    else
      r;

  # Bind extras via nix-effects. Leftover reserved args (or extras that are
  # themselves deferred) become a den-style thunk applied at evalModules.
  bindComputation =
    {
      parentHandlers,
      localHandlers,
    }:
    fn:
    let
      available = parentHandlers // localHandlers;
      extras = builtins.filter (n: available ? ${n}) (extraArgNames fn);
      allArgs = functionArgsOf fn;
      remaining = removeAttrs allArgs extras;
      remainingExtras = extraArgNames (lib.setFunctionArgs (_: { }) remaining);
      extrasOnly = lib.setFunctionArgs (extraVals: extraVals) (lib.genAttrs extras (_: false));
      computation =
        if extras == [ ] then
          fx.pure { }
        else
          fx.effects.scope.val localHandlers (fx.bind.fn { } extrasOnly);
      handled = fx.handle {
        handlers = handlersFrom parentHandlers;
        state = null;
      } computation;
      extraVals = handled.value;
    in
    {
      inherit extraVals remaining remainingExtras extras;
      boundCount = builtins.length extras;
    };

  anyThunk = attrs: builtins.any mark.isThunk (builtins.attrValues attrs);

  bindValue =
    ctx: fn:
    let
      step = bindComputation ctx fn;
      reservedLeft = builtins.filter (n: reservedArgs ? ${n}) (builtins.attrNames step.remaining);
      leftoverExtras = step.remainingExtras;
      needsDefer = leftoverExtras == [ ] && (reservedLeft != [ ] || anyThunk step.extraVals);
      value =
        if leftoverExtras != [ ] then
          fn
        else if needsDefer then
          mark.mkThunk (
            modArgs:
            let
              resolvedExtras = lib.mapAttrs (_: resolveThunk modArgs) step.extraVals;
              reserved = lib.intersectAttrs step.remaining (modArgs // { inherit lib; });
            in
            fn (resolvedExtras // reserved)
          )
        else
          fn step.extraVals;
    in
    {
      inherit value leftoverExtras;
      inherit (step) boundCount;
      progress = leftoverExtras == [ ] && (step.boundCount > 0 || needsDefer);
    };

  bindOverlay =
    ctx: fn:
    let
      step = bindComputation ctx fn;
      remainingNames = builtins.attrNames step.remaining;
      leftoverExtras = step.remainingExtras;
      advertised =
        if leftoverExtras != [ ] then
          functionArgsOf fn
        else if remainingNames != [ ] then
          step.remaining
        else if anyThunk step.extraVals then
          reservedArgs
        else
          { };
      wrapper =
        { ... }@modArgs:
        let
          resolvedExtras = lib.mapAttrs (_: resolveThunk modArgs) step.extraVals;
          reserved = lib.intersectAttrs step.remaining (modArgs // { inherit lib; });
        in
        resolveDeep modArgs (fn (resolvedExtras // reserved));
      value =
        if leftoverExtras != [ ] then
          fn
        else if advertised == { } then
          fn step.extraVals
        else
          lib.setFunctionArgs wrapper advertised;
    in
    {
      inherit value leftoverExtras;
      inherit (step) boundCount;
      progress = leftoverExtras == [ ] && (step.boundCount > 0 || advertised != functionArgsOf fn);
    };

  flattenSameScope =
    node:
    if lib.isFunction node then
      [ node ]
    else if builtins.isAttrs node && node ? imports then
      lib.concatMap flattenSameScope (lib.toList node.imports)
      ++ [
        (removeAttrs node [ "imports" ])
      ]
    else
      [ node ];

  emptyClass = {
    overlayFns = [ ];
    valueFns = [ ];
    modules = [ ];
    injects = { };
    exports = { };
    scopes = { };
  };

  mergeNamed =
    a: b:
    a
    // lib.mapAttrs (
      name: bVal:
      if a ? ${name} then
        {
          imports = [
            a.${name}
            bVal
          ];
        }
      else
        bVal
    ) b;

  mergeClass =
    a: b:
    {
      overlayFns = a.overlayFns ++ b.overlayFns;
      valueFns = a.valueFns ++ b.valueFns;
      modules = a.modules ++ b.modules;
      injects = a.injects // b.injects;
      exports = a.exports // b.exports;
      scopes = mergeNamed a.scopes b.scopes;
    };

  classifyMarked =
    name: marked:
    let
      inner = mark.unwrap marked;
      export = mark.isExport marked;
    in
    if isValueFn inner then
      {
        inherit (emptyClass)
          overlayFns
          modules
          injects
          exports
          scopes
          ;
        valueFns = [
          {
            inherit name export;
            fn = inner;
          }
        ];
      }
    else if export then
      emptyClass
      // {
        exports.${name} = inner;
      }
    else
      emptyClass
      // {
        injects.${name} = inner;
      };

  # Undeclared path component is an overlay result key, not a nested overlay.
  wrapAsKey =
    name: fn:
    if lib.isFunction fn then
      let
        wanted = functionArgsOf fn;
        wrapper =
          { ... }@args:
          {
            ${name} = fn (if wanted == { } then args else lib.intersectAttrs wanted args);
          };
      in
      lib.setFunctionArgs wrapper wanted
    else
      { ${name} = fn; };

  classifyOne =
    node:
    if mark.isMarked node then
      classifyMarked "<anon>" node
    else if isParametric node then
      emptyClass
      // {
        overlayFns = [ node ];
      }
    else if lib.isFunction node && extraArgNames node == [ ] then
      let
        args = functionArgsOf node;
        needsOverlayArgs = args ? final || args ? prev;
        body = if needsOverlayArgs then null else applyReserved node;
      in
      if
        body != null
        && builtins.isAttrs body
        && !lib.isFunction body
        && hasWork body
      then
        classifyOne body
      else
        emptyClass
        // {
          modules = [ node ];
        }
    else if lib.isFunction node then
      emptyClass
      // {
        modules = [ node ];
      }
    else if !(builtins.isAttrs node) then
      emptyClass
    else
      let
        attrs = removeAttrs node (
          builtins.attrNames reservedKeys
          ++ [
            "_scope"
          ]
        );
        configPart = if attrs ? config then classifyOne attrs.config else emptyClass;
        rest = removeAttrs attrs [
          "config"
          "options"
        ];
        folded = lib.foldlAttrs (
          acc: name: value:
          if mark.isMarked value then
            mergeClass acc (classifyMarked name value)
          else if isParametric value then
            acc
            // {
              overlayFns = acc.overlayFns ++ [ (wrapAsKey name value) ];
            }
          else if lib.isFunction value then
            acc
            // {
              modules = acc.modules ++ [ (wrapAsKey name value) ];
            }
          else if mark.isDeclaredScope value then
            acc
            // {
              scopes = mergeNamed acc.scopes {
                ${name} = removeAttrs value [ "_scope" ];
              };
            }
          else if builtins.isAttrs value && !lib.isFunction value && hasWork value then
            let
              inner = classifyOne value;
              nest = x: wrapAsKey name x;
            in
            mergeClass acc {
              overlayFns = map nest inner.overlayFns;
              valueFns = inner.valueFns;
              modules = map (m: if lib.isFunction m then nest m else { ${name} = m; }) inner.modules;
              inherit (inner) injects exports scopes;
            }
          else
            acc
            // {
              modules = acc.modules ++ [ { ${name} = value; } ];
            }
        ) emptyClass rest;
      in
      mergeClass folded configPart;

  collect = node: builtins.foldl' mergeClass emptyClass (map classifyOne (flattenSameScope node));

  expandItem =
    item:
    if
      builtins.isAttrs item
      && !lib.isFunction item
      && item ? imports
      && !(item ? config)
      && !(item ? options)
    then
      lib.concatMap expandItem (lib.toList item.imports)
    else
      [ item ];

  markTree =
    injects: exports:
    lib.mapAttrs (n: v: mark.inject v) injects
    // lib.mapAttrs (n: v: mark.export v) exports;

  # Several undeclared keys under the same path become several functions
  # that each return `{ bar.baz.key = … }`. Merge those results instead
  # of evalModules, which treats nested keys as unique `raw` options.
  combineFns =
    fns:
    if fns == [ ] then
      { }
    else if builtins.length fns == 1 then
      builtins.head fns
    else
      let
        advertised = builtins.foldl' (a: f: a // functionArgsOf f) { } fns;
        wrapper =
          { ... }@args:
          builtins.foldl' (
            acc: f:
            let
              wanted = functionArgsOf f;
              supplied = if wanted == { } then args else lib.intersectAttrs wanted args;
              result = f supplied;
            in
            if isOverlayAttrs acc && isOverlayAttrs result then
              lib.recursiveUpdate acc result
            else if isOverlayAttrs acc && acc == { } then
              result
            else
              throw "den.overlays: cannot merge overlay fragments that are not attribute sets"
          ) { } fns;
      in
      lib.setFunctionArgs wrapper advertised;

  assemble =
    {
      modules,
      boundOverlays,
      injects,
      exports,
      scopes,
    }:
    let
      scopeItems = lib.mapAttrsToList (name: value: { ${name} = value; }) scopes;
      marked = markTree injects exports;
      items = lib.concatMap expandItem (
        modules ++ boundOverlays ++ lib.optional (marked != { }) marked ++ scopeItems
      );
      fns = builtins.filter lib.isFunction items;
      attrs = builtins.filter (x: builtins.isAttrs x && !lib.isFunction x) items;
      merged = builtins.foldl' lib.recursiveUpdate { } attrs;
      combined = combineFns fns;
    in
    if fns == [ ] then
      merged
    else if attrs == [ ] then
      combined
    else
      {
        imports = [
          combined
          merged
        ];
      };

  isDerivation = v: builtins.isAttrs v && !lib.isFunction v && (v.type or null) == "derivation";

  isOverlayAttrs =
    v: builtins.isAttrs v && !lib.isFunction v && !mark.isMarked v && !mark.isThunk v && !isDerivation v;

  # Inject extras are omitted. Export extras keep their mark: the extra
  # name is scope-only and is stripped when the overlay result is flattened.
  finalize =
    node:
    if mark.isInject node then
      { }
    else if mark.isExport node then
      mark.export (finalize node.value)
    else if lib.isFunction node then
      node
    else if builtins.isList node then
      map finalize node
    else if builtins.isAttrs node then
      let
        attrs = removeAttrs node (builtins.attrNames reservedKeys);
        kept = lib.filterAttrs (_n: v: !mark.isInject v) attrs;
      in
      lib.mapAttrs (
        n: v:
        if n == "imports" then
          map finalize (lib.toList v)
        else if n == "options" then
          v
        else
          finalize v
      ) kept
    else
      node;

  mergeOverlayContents =
    parts:
    let
      nonempty = builtins.filter (p: !(isOverlayAttrs p && p == { })) parts;
      attrParts = builtins.filter isOverlayAttrs nonempty;
      otherParts = builtins.filter (p: !isOverlayAttrs p) nonempty;
    in
    if otherParts == [ ] then
      builtins.foldl' lib.recursiveUpdate { } attrParts
    else if attrParts == [ ] && builtins.length otherParts == 1 then
      builtins.head otherParts
    else if attrParts == [ ] then
      throw "den.overlays: multiple non-attrset export contents in one overlay (extra names are not overlay keys; each export's value is content)"
    else
      throw "den.overlays: cannot mix attrset overlay content with a non-attrset export (extra names are not overlay keys; an exported derivation is the overlay result, not `{ name = drv }` )";

  # Extra names are not overlay keys. Unmarked structure keeps its keys;
  # export values are spliced in as overlay content.
  flattenContent =
    node:
    if mark.isInject node then
      { }
    else if mark.isExport node then
      flattenContent node.value
    else if lib.isFunction node || builtins.isList node then
      node
    else if isOverlayAttrs node then
      let
        attrs = removeAttrs node (builtins.attrNames reservedKeys);
        unmarked = lib.concatMapAttrs (
          n: v:
          if n == "_scope" || mark.isInject v then
            { }
          else if n == "imports" then
            {
              imports = map flattenContent (lib.toList v);
            }
          else if n == "options" then
            {
              inherit (node) options;
            }
          else if mark.isExport v then
            {
              ${n} = flattenContent v;
            }
          else
            {
              ${n} = flattenContent v;
            }
        ) attrs;
      in
      unmarked
    else
      node;

  bindLoop' =
    parentHandlers: node: depth:
    if depth <= 0 then
      throw "den.overlays: bind loop exceeded iteration limit"
    else
      let
        classified = collect node;
        localHandlers = classified.injects // classified.exports;
        childParent = parentHandlers // localHandlers;
        ctx = {
          inherit parentHandlers localHandlers;
        };
        valueResults = map (e: (bindValue ctx e.fn) // { inherit (e) name export; }) classified.valueFns;
        overlayResults = map (bindOverlay ctx) classified.overlayFns;
        newInjects =
          classified.injects
          // lib.listToAttrs (
            map (r: {
              name = r.name;
              value = r.value;
            }) (builtins.filter (r: !r.export) valueResults)
          );
        newExports =
          classified.exports
          // lib.listToAttrs (
            map (r: {
              name = r.name;
              value = r.value;
            }) (builtins.filter (r: r.export) valueResults)
          );
        boundOverlays = map (r: r.value) overlayResults;
        leftover = lib.unique (
          builtins.concatLists (map (r: r.leftoverExtras) (overlayResults ++ valueResults))
        );
        progress =
          builtins.any (r: r.progress) valueResults || builtins.any (r: r.progress) overlayResults;
        processedScopes = lib.mapAttrs (
          _: scope: bindLoop' childParent scope (depth - 1)
        ) classified.scopes;
        # Force nested scopes now so an out-of-scope extra under a child
        # fails during conversion, not when that overlay is applied.
        _forceScopes = builtins.foldl' (_: v: builtins.seq v true) true (
          builtins.attrValues processedScopes
        );
        next = assemble {
          inherit (classified) modules;
          inherit boundOverlays;
          injects = newInjects;
          exports = newExports;
          scopes = processedScopes;
        };
        availableNames = lib.sort (a: b: a < b) (builtins.attrNames childParent);
        leftoverMsg = "den.overlays: extra${
          if builtins.length leftover == 1 then "" else "s"
        } ${lib.concatMapStringsSep ", " (n: "`${n}`") leftover} not in this scope (inject/export extras are named by their last path component and are visible on the declaring scope and descendants; declare a scope with `_scope = true`, e.g. `den.overlays.group._scope = true` makes `group.test1` available as `test1` under `group`). In scope: ${
          if availableNames == [ ] then
            "(none)"
          else
            lib.concatMapStringsSep ", " (n: "`${n}`") availableNames
        }";
      in
      if !_forceScopes then
        throw "den.overlays: internal error forcing nested scopes"
      else if classified.valueFns == [ ] && classified.overlayFns == [ ] then
        next
      else if leftover != [ ] && !progress then
        throw leftoverMsg
      else if !progress then
        next
      else
        bindLoop' parentHandlers next (depth - 1);

  bindLoop = node: parentHandlers: bindLoop' parentHandlers node 16;

  overlayFreeform = {
    freeformType = lib.types.lazyAttrsOf lib.types.raw;
  };

  # evalModules always supplies lib/config/options/…. Restrict the call
  # to the function's declared args so `{ final }: …` is a valid module.
  asModuleFn =
    fn:
    let
      wanted = functionArgsOf fn;
      wrapper =
        { ... }@args: fn (if wanted == { } then args else lib.intersectAttrs wanted args);
    in
    lib.setFunctionArgs wrapper wanted;

  toEvalModule =
    node:
    if lib.isFunction node then
      asModuleFn node
    else if builtins.isAttrs node && (node ? imports || node ? config || node ? options) then
      node
    else if builtins.isAttrs node then
      {
        inherit (overlayFreeform) freeformType;
        config = node;
      }
    else
      { config = { }; };

  mkEvalArgs =
    node: extraSpecialArgs:
    {
      modules = [
        overlayFreeform
        (toEvalModule node)
      ];
      specialArgs = extraSpecialArgs;
    };

  evalOverlayModule =
    node: extraSpecialArgs:
    let
      evalArgs = mkEvalArgs node extraSpecialArgs;
      evaluated = lib.evalModules evalArgs;
    in
    {
      inherit (evaluated) config;
      inherit evalArgs;
      modules = evalArgs.modules;
    };

  applyOverlay =
    ready: final: prev:
    let
      callArgs = dummyModuleArgs // {
        inherit final prev;
      };
      called =
        if lib.isFunction ready then
          let
            args = functionArgsOf ready;
            supplied = if args == { } then callArgs else lib.intersectAttrs args callArgs;
          in
          ready supplied
        else
          ready;
      resolvedCall = resolveDeep (
        callArgs
        // {
          config = { };
        }
      ) called;
    in
    if isOverlayAttrs resolvedCall then
      let
        evaluated = evalOverlayModule ready {
          inherit final prev;
        };
        resolved = resolveDeep {
          inherit
            final
            prev
            lib
            ;
          inherit (evaluated) config;
        } evaluated.config;
        content = flattenContent resolved;
      in
      if isOverlayAttrs content then
        removeAttrs content [ "_module" ]
      else
        content
    else
      flattenContent resolvedCall;

  toOverlayWith =
    parentHandlers: module:
    let
      bound = bindLoop module parentHandlers;
      ready = finalize bound;
    in
    # Force bind during conversion. Unbound extras must not wait until
    # `overlay final prev` / nixpkgs import.
    builtins.seq bound (applyOverlay ready);

  toOverlay = toOverlayWith { };

  extraHandlersOf =
    bound:
    if builtins.isAttrs bound && !lib.isFunction bound then
      lib.concatMapAttrs (
        name: value:
        if mark.isInject value || mark.isExport value then
          {
            ${name} = mark.unwrap value;
          }
        else
          { }
      ) bound
    else
      { };

  exportOverlay =
    value:
    let
      ready = mark.export value;
    in
    final: prev:
    let
      resolved = resolveDeep {
        inherit final prev lib;
        config = { };
      } ready;
    in
    flattenContent (mark.unwrap resolved);

  overlayNameOf =
    path:
    if path == [ ] then
      throw "den.overlays: internal error: overlay at empty path"
    else
      lib.concatStringsSep "/" path;

  asNixpkgsOverlay =
    name: ov: final: prev:
    let
      result = ov final prev;
    in
    if isOverlayAttrs result then
      result
    else
      {
        ${name} = result;
      };

  extrasAtLevel =
    node:
    if isOverlayAttrs node then
      lib.concatMapAttrs (
        name: value:
        if name == "_scope" then
          { }
        else if mark.isInject value || mark.isExport value then
          {
            ${name} = value;
          }
        else
          { }
      ) node
    else
      { };

  # Promote ancestors of module-path leaves. A leaf is inject, export, or
  # a function; those paths are overlay/extra names, not content keys.
  # Plain attrsets stay content unless `_scope = true` (or they sit on
  # the path to a module leaf).
  promoteScopes =
    node:
    if !isOverlayAttrs node then
      node
    else
      let
        children = lib.mapAttrs (_: promoteScopes) (
          removeAttrs node (
            builtins.attrNames reservedKeys
            ++ [
              "_scope"
            ]
          )
        );
        childDeclares = builtins.any (
          v: mark.isDeclaredScope v || mark.isModuleLeaf v
        ) (builtins.attrValues children);
      in
      if (node._scope or false) == true || childDeclares then
        children // { _scope = true; }
      else
        children // lib.optionalAttrs (node ? _scope) { inherit (node) _scope; };

  # Root `den.overlays` is an implicit scope. Nested attrsets become
  # scopes when they lead to a function/inject/export or set `_scope`.
  walkOverlays =
    path: parentHandlers: node:
    if mark.isInject node then
      {
        overlays = { };
        force = true;
      }
    else if mark.isExport node then
      {
        overlays = {
          ${overlayNameOf path} = asNixpkgsOverlay (lib.last path) (
            exportOverlay (parentHandlers.${lib.last path} or (mark.unwrap node))
          );
        };
        force = builtins.seq (bindLoop { ${lib.last path} = node; } parentHandlers) true;
      }
    else if (path != [ ] && mark.isDeclaredScope node) || (path == [ ] && isOverlayAttrs node) then
      let
        children = removeAttrs node (
          builtins.attrNames reservedKeys
          ++ [
            "_scope"
          ]
        );
        extras = extrasAtLevel children;
        boundExtras = if extras == { } then { } else bindLoop extras parentHandlers;
        handlers = parentHandlers // extraHandlersOf boundExtras;
        childResults = lib.mapAttrsToList (
          name: value: walkOverlays (path ++ [ name ]) handlers value
        ) children;
        overlays = builtins.foldl' (a: r: a // r.overlays) { } childResults;
        force =
          builtins.seq boundExtras (
            builtins.foldl' (a: r: builtins.seq r.force a) true childResults
          );
      in
      {
        inherit overlays force;
      }
    else
      {
        overlays = {
          ${overlayNameOf path} = asNixpkgsOverlay (lib.last path) (toOverlayWith parentHandlers node);
        };
        force = builtins.seq (bindLoop node parentHandlers) true;
      };

  toOverlays =
    attrs:
    let
      walked = walkOverlays [ ] { } (promoteScopes attrs);
    in
    builtins.seq walked.force walked.overlays;
in
{
  inherit
    collect
    bindValue
    bindOverlay
    bindLoop
    evalOverlayModule
    mkEvalArgs
    toOverlay
    toOverlayWith
    toOverlays
    extraArgNames
    handlersFrom
    finalize
    resolveDeep
    mark
    ;
  inherit (mark) inject export scope;
  __functor = self: self.toOverlays;
}
