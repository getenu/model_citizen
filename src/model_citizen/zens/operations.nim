import std/[typetraits, macros, macrocache, tables]
import model_citizen/[core, components/private/tracking, types {.all.}]
import ./[contexts, validations, private]

proc untrack_all*[T, O](self: Zen[T, O]) =
  private_access ZenObject[T, O]
  private_access ZenBase
  private_access ZenContext
  assert self.valid
  self.trigger_callbacks(@[Change.init(O, {CLOSED})])
  for zid, _ in self.changed_callbacks.pairs:
    self.ctx.close_procs.del(zid)

  for zid in self.bound_zids:
    self.ctx.untrack(zid)

  self.changed_callbacks.clear

proc untrack*(ctx: ZenContext, zid: ZID) =
  private_access ZenContext

  # :(
  if zid in ctx.close_procs:
    ctx.close_procs[zid]()
    debug "deleting close proc", zid
    ctx.close_procs.del(zid)
  else:
    debug "No close proc for zid", zid = zid

proc contains*[T, O](self: Zen[T, O], child: O): bool =
  privileged
  assert self.valid
  child in self.tracked

proc contains*[K, V](self: ZenTable[K, V], key: K): bool =
  privileged
  assert self.valid
  key in self.tracked

proc contains*[T, O](self: Zen[T, O], children: set[O] | seq[O]): bool =
  assert self.valid
  result = true
  for child in children:
    if child notin self:
      return false

proc clear*[T, O](self: Zen[T, O]) =
  assert self.valid
  mutate(OperationContext(source: [self.ctx.id].toHashSet)):
    self.tracked = T.default

proc `value=`*[T, O](self: Zen[T, O], value: T, op_ctx = OperationContext()) =
  privileged
  assert self.valid
  self.ctx.setup_op_ctx
  if self.tracked != value:
    mutate(op_ctx):
      self.tracked = value

proc value*[T, O](self: Zen[T, O]): T =
  privileged
  assert self.valid
  self.tracked

proc `[]`*[K, V](self: Zen[Table[K, V], Pair[K, V]], index: K): V =
  privileged
  assert self.valid
  self.tracked[index]

proc `[]`*[T](self: ZenSeq[T], index: SomeOrdinal | BackwardsIndex): T =
  privileged
  assert self.valid
  self.tracked[index]

proc `[]=`*[K, V](
    self: ZenTable[K, V], key: K, value: V, op_ctx = OperationContext()
) =
  self.ctx.setup_op_ctx
  self.put(key, value, touch = false, op_ctx)

proc `[]=`*[T](
    self: ZenSeq[T], index: SomeOrdinal, value: T, op_ctx = OperationContext()
) =
  self.ctx.setup_op_ctx
  assert self.valid
  mutate(op_ctx):
    self.tracked[index] = value

proc add*[T, O](self: Zen[T, O], value: O, op_ctx = OperationContext()) =
  privileged
  self.ctx.setup_op_ctx
  when O is Zen:
    assert self.valid(value)
  else:
    assert self.valid
  self.tracked.add value
  let added = @[Change.init(value, {ADDED})]
  self.link_or_unlink(added, true)
  when O isnot Zen and O is ref:
    self.ctx.ref_count(added, self.id)

  self.publish_changes(added, op_ctx)
  self.trigger_callbacks(added)

proc del*[T, O](self: Zen[T, O], value: O, op_ctx = OperationContext()) =
  privileged
  self.ctx.setup_op_ctx
  assert self.valid
  if value in self.tracked:
    remove(self, value, value, del, op_ctx)

proc del*[K, V](self: ZenTable[K, V], key: K, op_ctx = OperationContext()) =
  privileged
  self.ctx.setup_op_ctx
  assert self.valid
  if key in self.tracked:
    remove(
      self, key, Pair[K, V](key: key, value: self.tracked[key]), del, op_ctx
    )

proc del*[T: seq, O](
    self: Zen[T, O], index: SomeOrdinal, op_ctx = OperationContext()
) =
  privileged

  self.ctx.setup_op_ctx
  assert self.valid
  if index < self.tracked.len:
    remove(self, index, self.tracked[index], del, op_ctx)

proc delete*[T, O](self: Zen[T, O], value: O) =
  assert self.valid
  if value in self.tracked:
    remove(
      self,
      value,
      value,
      delete,
      op_ctx = OperationContext(source: [self.ctx.id].toHashSet),
    )

proc delete*[K, V](self: ZenTable[K, V], key: K) =
  assert self.valid
  if key in self.tracked:
    remove(
      self,
      key,
      Pair[K, V](key: key, value: self.tracked[key]),
      delete,
      op_ctx = OperationContext(),
    )

proc delete*[T: seq, O](self: Zen[T, O], index: SomeOrdinal) =
  assert self.valid
  if index < self.tracked.len:
    remove(
      self, index, self.tracked[index], delete, op_ctx = OperationContext()
    )

proc touch*[K, V](
    self: ZenTable[K, V], pair: Pair[K, V], op_ctx: OperationContext
) =
  assert self.valid
  self.put(pair.key, pair.value, touch = true, op_ctx = op_ctx)

proc touch*[T, O](
    self: ZenTable[T, O], key: T, value: O, op_ctx = OperationContext()
) =
  assert self.valid
  self.put(key, value, touch = true, op_ctx = op_ctx)

proc touch*[T: set, O](self: Zen[T, O], value: O, op_ctx = OperationContext()) =
  assert self.valid
  self.change_and_touch({value}, true, op_ctx = op_ctx)

proc touch*[T: seq, O](self: Zen[T, O], value: O, op_ctx = OperationContext()) =
  assert self.valid
  self.change_and_touch(@[value], true, op_ctx = op_ctx)

proc touch*[T, O](self: Zen[T, O], value: T, op_ctx = OperationContext()) =
  assert self.valid
  self.change_and_touch(value, true, op_ctx = op_ctx)

proc touch*[T](self: ZenValue[T], value: T, op_ctx = OperationContext()) =
  assert self.valid
  mutate_and_touch(touch = true, op_ctx):
    self.tracked = value

proc len*(self: Zen): int =
  privileged
  assert self.valid
  self.tracked.len

proc `+`*[O](self, other: ZenSet[O]): set[O] =
  privileged
  self.tracked + other.tracked

proc `+=`*[T, O](self: Zen[T, O], value: T) =
  assert self.valid
  self.change(value, true, op_ctx = OperationContext())

proc `+=`*[O](self: ZenSet[O], value: O) =
  assert self.valid
  self.change({value}, true, op_ctx = OperationContext())

proc `+=`*[T: seq, O](self: Zen[T, O], value: O) =
  assert self.valid
  self.add(value)

proc `+=`*[T, O](self: ZenTable[T, O], other: Table[T, O]) =
  assert self.valid
  self.put_all(other, touch = false, op_ctx = OperationContext())

proc `-=`*[T, O](self: Zen[T, O], value: T) =
  assert self.valid
  self.change(value, false, op_ctx = OperationContext())

proc `-=`*[T: set, O](self: Zen[T, O], value: O) =
  assert self.valid
  self.change({value}, false, op_ctx = OperationContext())

proc `-=`*[T: seq, O](self: Zen[T, O], value: O) =
  assert self.valid
  self.change(@[value], false, op_ctx = OperationContext())

proc `&=`*[T, O](self: Zen[T, O], value: O) =
  assert self.valid
  self.value = self.value & value

proc `==`*(a, b: Zen): bool =
  privileged
  a.is_nil == b.is_nil and a.destroyed == b.destroyed and a.tracked == b.tracked and
    a.id == b.id

proc pause_changes*(self: Zen, zids: varargs[ZID]) =
  assert self.valid
  if zids.len == 0:
    for zid in self.changed_callbacks.keys:
      self.paused_zids.incl(zid)
  else:
    for zid in zids:
      self.paused_zids.incl(zid)

proc resume_changes*(self: Zen, zids: varargs[ZID]) =
  assert self.valid
  if zids.len == 0:
    self.paused_zids = {}
  else:
    for zid in zids:
      self.paused_zids.excl(zid)

template pause_impl(self: Zen, zids: untyped, body: untyped) =
  private_access ZenBase

  let previous = self.paused_zids
  for zid in zids:
    self.paused_zids.incl(zid)
  try:
    body
  finally:
    self.paused_zids = previous

template pause*(self: Zen, zids: varargs[ZID], body: untyped) =
  mixin valid
  assert self.valid
  pause_impl(self, zids, body)

template pause*(self: Zen, body: untyped) =
  private_access ZenObject
  mixin valid
  assert self.valid
  pause_impl(self, self.changed_callbacks.keys, body)

proc destroy*[T, O](self: Zen[T, O], publish = true) =
  log_defaults
  debug "destroying", unit = self.id, stack = get_stack_trace()
  assert self.valid
  self.untrack_all
  self.destroyed = true
  self.ctx.objects[self.id] = nil
  self.ctx.objects_need_packing = true

  if publish:
    self.publish_destroy OperationContext(source: [self.ctx.id].toHashSet)

proc `~=`*[T, O](a: Zen[T, O], b: T) =
  `value=`(a, b)

proc `~==`*[T, O](a: Zen[T, O], b: T): bool =
  value(a) == b

proc `~==~`*[T, O](a: Zen[T, O], b: Zen[T, O]): bool =
  value(a) == value(b)

proc `?~`*[T](self: ZenValue[T]): bool =
  ? ~self

iterator items*[T](self: ZenSet[T] | ZenSeq[T]): T =
  privileged
  assert self.valid
  for item in self.tracked.items:
    yield item

iterator items*[K, V](self: ZenTable[K, V]): Pair[K, V] =
  privileged
  assert self.valid
  for key, value in self.tracked.pairs:
    yield Pair[K, V](key: key, value: value)

iterator pairs*[K, V](self: ZenTable[K, V]): (K, V) =
  privileged
  assert self.valid
  for pair in self.tracked.pairs:
    yield pair
