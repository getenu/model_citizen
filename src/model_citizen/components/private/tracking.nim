import
  std/[importutils, tables, sets, sequtils, algorithm, intsets, locks, sugar]

import pkg/[flatty, supersnappy, threading/channels {.all.}]
import
  model_citizen/
    [core, components/type_registry, zens/contexts, zens/private, types {.all.}]

proc `-`*[T](a, b: seq[T]): seq[T] =
  a.filter proc(it: T): bool =
    it notin b

template `&`*[T](a, b: set[T]): set[T] =
  a + b

proc trigger_callbacks*[T, O](self: Zen[T, O], changes: seq[Change[O]]) =
  private_access ZenObject[T, O]
  private_access ZenBase

  if changes.len > 0:
    let callbacks = self.changed_callbacks.dup
    for zid, callback in callbacks.pairs:
      if zid in self.changed_callbacks and zid notin self.paused_zids:
        callback(changes)

proc link_child*[K, V](
    self: ZenTable[K, V], child, obj: Pair[K, V], field_name = ""
) =
  proc link[S, K, V, T, O](self: S, pair: Pair[K, V], child: Zen[T, O]) =
    private_access ZenBase
    log_defaults
    child.link_zid = child.track proc(changes: seq[Change[O]]) =
      if changes.len == 1 and changes[0].changes == {CLOSED}:
        # Don't propagate CLOSED changes
        return
      let change = Change.init(pair, {MODIFIED})
      change.triggered_by = cast[seq[BaseChange]](changes)
      change.triggered_by_type = $O
      self.trigger_callbacks(@[change])
    debug "linking zen",
      child = ($child.type, $child.id), self = ($self.type, $self.id)

  if ?child.value:
    self.link(child, child.value)

proc link_child*[T, O, L](self: ZenSeq[T], child: O, obj: L, field_name = "") =
  let
    field_name = field_name
    self = self
    obj = obj
  proc link[T, O](child: Zen[T, O]) =
    private_access ZenBase
    log_defaults
    child.link_zid = child.track proc(changes: seq[Change[O]]) =
      if changes.len == 1 and changes[0].changes == {CLOSED}:
        # Don't propagate CLOSED changes
        return

      let change = Change.init(obj, {MODIFIED}, field_name = field_name)
      change.triggered_by = cast[seq[BaseChange]](changes)
      change.triggered_by_type = $O
      self.trigger_callbacks(@[change])
    debug "linking zen",
      child = ($child.type, $child.id),
      self = ($self.type, $self.id),
      zid = child.link_zid,
      child_addr = cast[int](unsafe_addr child[]).to_hex

  if ?child:
    link(child)

proc unlink*(self: Zen) =
  private_access ZenBase
  log_defaults
  debug "unlinking", id = self.id, zid = self.link_zid
  self.untrack(self.link_zid)
  self.link_zid = 0

proc unlink*[T: Pair](pair: T) =
  log_defaults
  debug "unlinking", id = pair.value.id, zid = pair.value.link_zid
  pair.value.untrack(pair.value.link_zid)
  pair.value.link_zid = 0

proc link_or_unlink*[T, O](self: Zen[T, O], change: Change[O], link: bool) =
  log_defaults
  template value(change: Change[Pair]): untyped =
    change.item.value

  template value(change: not Change[Pair]): untyped =
    change.item

  if TRACK_CHILDREN in self.flags:
    if link:
      when change.value is Zen:
        self.link_child(change.item, change.item)
      elif change.value is object or change.value is ref:
        for name, val in change.value.deref.field_pairs:
          when val is Zen:
            if ?val:
              debug "linking field", field = name, type = $change.value.type
              self.link_child(val, change.item, name)
    else:
      when change.value is Zen:
        if ?change.value:
          change.value.unlink
      elif change.value is object or change.value is ref:
        for n, field in change.value.deref.field_pairs:
          when field is Zen:
            if ?field and not field.destroyed:
              field.unlink

proc link_or_unlink*[T, O](
    self: Zen[T, O], changes: seq[Change[O]], link: bool
) =
  if TRACK_CHILDREN in self.flags:
    for change in changes:
      self.link_or_unlink(change, link)

proc process_changes*[T](
    self: Zen[T, T], initial: sink T, op_ctx: OperationContext, touch = false
) =
  private_access ZenObject[T, T]
  if initial != self.tracked:
    var add_flags = {ADDED, MODIFIED}
    var del_flags = {REMOVED, MODIFIED}
    if touch:
      add_flags.incl TOUCHED

    let changes =
      @[Change.init(initial, del_flags), Change.init(self.tracked, add_flags)]
    when T isnot Zen and T is ref:
      self.ctx.ref_count(changes, self.id)

    self.publish_changes(changes, op_ctx)
    self.trigger_callbacks(changes)
  elif touch:
    let changes = @[Change.init(self.tracked, {TOUCHED})]
    when T isnot Zen and T is ref:
      self.ctx.ref_count(changes, self.id)

    self.publish_changes(changes, op_ctx)
    self.trigger_callbacks(changes)

proc process_changes*[T: seq | set, O](
    self: Zen[T, O],
    initial: sink T,
    op_ctx: OperationContext,
    touch = T.default,
) =
  private_access ZenObject

  let added = (self.tracked - initial).map_it:
    let changes =
      if it in touch:
        {TOUCHED}
      else:
        {}
    Change.init(it, {ADDED} + changes)
  let removed = (initial - self.tracked).map_it Change.init(it, {REMOVED})

  var touched: seq[Change[O]]
  for item in touch:
    if item in initial:
      touched.add Change.init(item, {TOUCHED})

  self.link_or_unlink(removed, false)
  self.link_or_unlink(added, true)

  let changes = removed & added & touched
  when O isnot Zen and O is ref:
    self.ctx.ref_count(changes, self.id)

  self.publish_changes(changes, op_ctx)
  self.trigger_callbacks(changes)

proc process_changes*[K, V](
    self: Zen[Table[K, V], Pair[K, V]],
    initial_table: sink Table[K, V],
    op_ctx: OperationContext,
) =
  private_access ZenObject
  let
    tracked: seq[Pair[K, V]] = collect:
      for key, value in self.tracked.pairs:
        Pair[K, V](key: key, value: value)
    initial: seq[Pair[K, V]] = collect:
      for key, value in initial_table.pairs:
        Pair[K, V](key: key, value: value)
    added = (tracked - initial).map_it:
      var changes = {ADDED}
      if it.key in initial_table:
        changes.incl MODIFIED
      Change.init(it, changes)

    removed = (initial - tracked).map_it:
      var changes = {REMOVED}
      if it.key in self.tracked:
        changes.incl MODIFIED
      Change.init(it, changes)

  self.link_or_unlink(removed, false)
  self.link_or_unlink(added, true)
  let changes = removed & added
  when V isnot Zen and V is ref:
    self.ctx.ref_count(changes, self.id)

  self.publish_changes(changes, op_ctx)
  self.trigger_callbacks(changes)

template mutate_and_touch*(touch, op_ctx, body: untyped) =
  private_access ZenObject
  when self.tracked is Zen:
    let initial_values = self.tracked[]
  elif self.tracked is ref:
    let initial_values = self.tracked
  else:
    let initial_values = self.tracked.dup

  {.line.}:
    body
    self.process_changes(initial_values, op_ctx, touch)

template mutate*(op_ctx: OperationContext, body: untyped) =
  private_access ZenObject
  mixin dup
  when self.tracked is Zen:
    let initial_values = self.tracked[]
  elif self.tracked is ref:
    let initial_values = self.tracked
  else:
    let initial_values = self.tracked.dup

  {.line.}:
    body
    self.process_changes(initial_values, op_ctx)

proc change*[T, O](
    self: Zen[T, O], items: T, add: bool, op_ctx: OperationContext
) =
  mutate(op_ctx):
    if add:
      self.tracked = self.tracked & items
    else:
      self.tracked = self.tracked - items

proc change_and_touch*[T, O](
    self: Zen[T, O], items: T, add: bool, op_ctx: OperationContext
) =
  mutate_and_touch(touch = items, op_ctx):
    if add:
      self.tracked = self.tracked & items
    else:
      self.tracked = self.tracked - items

proc assign*[O](self: ZenSeq[O], value: O, op_ctx: OperationContext) =
  self.add(value, op_ctx = op_ctx)

proc assign*[O](self: ZenSeq[O], values: seq[O], op_ctx: OperationContext) =
  for value in values:
    self.add(value, op_ctx = op_ctx)

proc assign*[O](self: ZenSet[O], value: O, op_ctx: OperationContext) =
  self.change({value}, add = true, op_ctx = op_ctx)

proc assign*[K, V](
    self: ZenTable[K, V], pair: Pair[K, V], op_ctx: OperationContext
) =
  self.`[]=`(pair.key, pair.value, op_ctx = op_ctx)

proc assign*[T, O](self: Zen[T, O], value: O, op_ctx: OperationContext) =
  self.`value=`(value, op_ctx)

proc unassign*[O](self: ZenSeq[O], value: O, op_ctx: OperationContext) =
  self.change(@[value], false, op_ctx = op_ctx)

proc unassign*[O](self: ZenSet[O], value: O, op_ctx: OperationContext) =
  self.change({value}, false, op_ctx = op_ctx)

proc unassign*[K, V](
    self: ZenTable[K, V], pair: Pair[K, V], op_ctx: OperationContext
) =
  self.del(pair.key, op_ctx = op_ctx)

proc unassign*[T, O](self: Zen[T, O], value: O, op_ctx: OperationContext) =
  discard

proc build_changes[K, V](
    self: ZenTable[K, V], key: K, value: V, touch: bool
): seq[Change[Pair[K, V]]] =
  private_access ZenObject
  assert self.valid

  var changes: seq[Change[Pair[K, V]]]

  if key in self.tracked and self.tracked[key] != value:
    let removed = Change.init(
      Pair[K, V](key: key, value: self.tracked[key]), {REMOVED, MODIFIED}
    )

    var flags = {ADDED, MODIFIED}
    if touch:
      flags.incl TOUCHED
    let added = Change.init(Pair[K, V](key: key, value: value), flags)
    when value is Zen:
      if ?removed.item.value:
        self.link_or_unlink(removed, false)
      self.link_or_unlink(added, true)
    self.tracked[key] = value
    changes = @[removed, added]
  elif key in self.tracked and touch:
    changes.add Change.init(Pair[K, V](key: key, value: value), {TOUCHED})
  elif key notin self.tracked:
    let added = Change.init(Pair[K, V](key: key, value: value), {ADDED})
    when value is Zen:
      self.link_or_unlink(added, true)
    self.tracked[key] = value
    changes = @[added]

  result = changes

proc put_all*[K, V](
    self: ZenTable[K, V],
    other: Table[K, V],
    touch: bool,
    op_ctx: OperationContext,
) =
  var changes: seq[Change[Pair[K, V]]] = @[]
  for key, value in other:
    changes.add self.build_changes(key, value, touch)

  when V isnot Zen and V is ref:
    self.ctx.ref_count(changes, self.id)

  self.publish_changes changes, op_ctx
  self.trigger_callbacks changes

proc put*[K, V](
    self: ZenTable[K, V],
    key: K,
    value: V,
    touch: bool,
    op_ctx: OperationContext,
) =
  private_access ZenObject
  assert self.valid

  let changes = self.build_changes(key, value, touch)

  when V isnot Zen and V is ref:
    self.ctx.ref_count(changes, self.id)

  self.publish_changes changes, op_ctx
  self.trigger_callbacks changes

proc len*[T, O](self: Zen[T, O]): int =
  privileged
  assert self.valid
  self.tracked.len

template remove*(self, key, item_exp, fun, op_ctx) =
  let obj = item_exp
  self.tracked.fun key
  let removed = @[Change.init(obj, {REMOVED})]
  self.link_or_unlink(removed, false)
  when obj isnot Zen and obj is ref:
    self.ctx.ref_count(removed, self.id)

  self.publish_changes(removed, op_ctx)
  self.trigger_callbacks(removed)
