# Markers that distinguish the three overlay-tree roles:
#   1) inject  — resolved extra; in scope for descendants; not exported
#   2) export  — resolved extra; in scope for descendants; exported
#   3) unmarked overlay — module / overlay attrs; exported; not an extra
{
  inject = value: {
    _type = "den.inject";
    inherit value;
  };

  export = value: {
    _type = "den.export";
    inherit value;
  };

  isInject = v: builtins.isAttrs v && (v._type or null) == "den.inject";

  isExport = v: builtins.isAttrs v && (v._type or null) == "den.export";

  isMarked = v: (v._type or null) == "den.inject" || (v._type or null) == "den.export";

  unwrap = v: if (v._type or null) == "den.inject" || (v._type or null) == "den.export" then v.value else v;

  remake =
    mark: value:
    if (mark._type or null) == "den.inject" then
      {
        _type = "den.inject";
        inherit value;
      }
    else if (mark._type or null) == "den.export" then
      {
        _type = "den.export";
        inherit value;
      }
    else
      value;

  isThunk = v: builtins.isAttrs v && (v.__denDefer or false);

  mkThunk = fn: {
    __denDefer = true;
    __fn = fn;
  };

  # Function, inject, or export: the path to this value is a module path.
  isModuleLeaf =
    v:
    builtins.isFunction v
    || (
      builtins.isAttrs v
      && (
        (v._type or null) == "den.inject"
        || (v._type or null) == "den.export"
      )
    );

  # Explicit scope path. Undeclared attr paths are overlay content keys.
  isDeclaredScope =
    v:
    builtins.isAttrs v
    && !builtins.isFunction v
    && (v._type or null) != "den.inject"
    && (v._type or null) != "den.export"
    && !(v.__denDefer or false)
    && (v._scope or false) == true;

  # Mark this attrset as a scope. Ancestors become scopes automatically.
  scope = attrs: attrs // { _scope = true; };
}
