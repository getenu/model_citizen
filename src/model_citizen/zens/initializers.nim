import std/[typetraits, macros, macrocache]
import model_citizen/[core, components/private/tracking]
import
  model_citizen/types {.all.},
  model_citizen/zens/[validations, operations, contexts, private]

export new_ident_node

const initializers = CacheSeq"initializers"
var type_initializers: Table[int, CreateInitializer]
var initialized = false

proc ctx(): ZenContext =
  Zen.thread_ctx

proc create_initializer[T, O](self: Zen[T, O]) =
  const zen_type_id = self.type.tid

  static:
    initializers.add quote do:
      type_initializers[zen_type_id] = proc(
          bin: string,
          ctx: ZenContext,
          id: string,
          flags: set[ZenFlags],
          op_ctx: OperationContext,
      ) =
        mixin new_ident_node
        if bin != "":
          debug "creating received object", id
          if not ctx.subscribing and id notin ctx:
            var value = bin.from_flatty(T, ctx)
            discard Zen.init(value, ctx = ctx, id = id, flags = flags, op_ctx)
          elif not ctx.subscribing:
            debug "restoring received object", id
            var value = bin.from_flatty(T, ctx)
            let item = Zen[T, O](ctx[id])
            `value=`(item, value, op_ctx = op_ctx)
          else:
            if id notin ctx:
              discard Zen[T, O].init(ctx = ctx, id = id, flags = flags, op_ctx)

            let initializer = proc() =
              debug "deferred restore of received object value", id
              {.gcsafe.}:
                let value = bin.from_flatty(T, ctx)
              let item = Zen[T, O](ctx[id])
              `value=`(item, value, op_ctx = op_ctx)
            ctx.value_initializers.add(initializer)
        elif id notin ctx:
          discard Zen[T, O].init(ctx = ctx, id = id, flags = flags, op_ctx)

proc defaults[T, O](
    self: Zen[T, O], ctx: ZenContext, id: string, op_ctx: OperationContext
): Zen[T, O] =
  privileged
  log_defaults

  create_initializer(self)
  self.id =
    if id == "":
      $self.type & "-" & generate_id()
    else:
      id

  debug "creating zen object", id = self.id

  if self.id in ctx.objects and not ?ctx.objects[self.id]:
    ctx.pack_objects
  ctx.objects[self.id] = self

  self.publish_create = proc(
      sub: Subscription, broadcast: bool, op_ctx = OperationContext()
  ) =
    log_defaults "model_citizen publishing"
    debug "publish_create", sub

    {.gcsafe.}:
      let bin = self.tracked.to_flatty
    let id = self.id
    let flags = self.flags

    template send_msg(src_ctx, sub) =
      const zen_type_id = self.type.tid

      var msg = Message(
        kind: Create,
        obj: bin,
        flags: flags,
        type_id: zen_type_id,
        object_id: id,
        source: op_ctx.source,
      )

      when defined(zen_trace):
        msg.trace = get_stack_trace()

      src_ctx.send(sub, msg, op_ctx, flags = self.flags & {SyncAllNoOverwrite})

    if sub.kind != Blank:
      ctx.send_msg(sub)
    if broadcast:
      for sub in ctx.subscribers:
        if sub.ctx_id notin op_ctx.source:
          ctx.send_msg(sub)
    ctx.tick_reactor

  self.build_message = proc(
      self: ref ZenBase, change: BaseChange, id, trace: string
  ): Message =
    var msg = Message(object_id: id, type_id: Zen[T, O].tid)
    when defined(zen_trace):
      msg.trace = trace
    assert Added in change.changes or Removed in change.changes or
      Touched in change.changes
    let change = Change[O](change)
    when change.item is Zen:
      msg.change_object_id = change.item.id
    elif change.item is Pair[auto, Zen]:
      # TODO: Properly sync ref keys
      {.gcsafe.}:
        msg.obj = change.item.key.to_flatty
      msg.change_object_id = change.item.value.id
    else:
      var item = ""
      block registered:
        when change.item is ref RootObj:
          if ?change.item:
            var registered_type: RegisteredType
            if change.item.lookup_type(registered_type):
              msg.ref_id = registered_type.tid
              item = registered_type.stringify(change.item)
              break registered
            else:
              debug "type not registered", type_name = change.item.base_type

        {.gcsafe.}:
          item = change.item.to_flatty
      msg.obj = item

    msg.kind =
      if Touched in change.changes:
        Touch
      elif Added in change.changes:
        Assign
      elif Removed in change.changes:
        Unassign
      else:
        fail "Can't build message for changes " & $change.changes
    result = msg

  self.change_receiver = proc(
      self: ref ZenBase, msg: Message, op_ctx: OperationContext
  ) =
    assert self of Zen[T, O]
    let self = Zen[T, O](self)

    if msg.kind == Destroy:
      self.destroy
      return

    when O is Zen:
      let object_id = msg.change_object_id
      assert object_id in self.ctx
      let item = O(self.ctx.objects[object_id])
    elif O is Pair[auto, Zen]:
      # Workaround for compile issue. This should be `O`, not `O.default.type`.
      type K = generic_params(O.default.type).get(0)
      type V = generic_params(O.default.type).get(1)
      if msg.object_id notin self.ctx:
        when defined(zen_trace):
          echo msg.trace
        fail "object not in context " & msg.object_id & " " & $Zen[T, O]

      if msg.change_object_id notin self.ctx and msg.kind == Unassign:
        debug "can't find ", obj = msg.change_object_id
        return
      let value = V(self.ctx.objects[msg.change_object_id])
      {.gcsafe.}:
        let item = O(key: msg.obj.from_flatty(K, self.ctx), value: value)
    else:
      var item: O
      when item is ref RootObj:
        if msg.obj != "":
          if msg.ref_id != 0:
            var registered_type: RegisteredType
            if lookup_type(msg.ref_id, registered_type):
              item = type(item)(registered_type.parse(self.ctx, msg.obj))
              if not self.ctx.find_ref(item):
                debug "item restored (not found)",
                  item = item.type.name, ref_id = item.ref_id
              else:
                debug "item found (not restored)",
                  item = item.type.name, ref_id = item.ref_id
            else:
              fail \"Type for ref_id {msg.ref_id} not registered"
          else:
            {.gcsafe.}:
              item = msg.obj.from_flatty(O, self.ctx)
      else:
        {.gcsafe.}:
          item = msg.obj.from_flatty(O, self.ctx)

    if msg.kind == Assign:
      self.assign(item, op_ctx = op_ctx)
    elif msg.kind == Unassign:
      self.unassign(item, op_ctx = op_ctx)
    elif msg.kind == Touch:
      self.touch(item, op_ctx = op_ctx)
    else:
      fail "Can't handle message " & $msg.kind

  assert self.ctx == nil
  self.ctx = ctx

  self.publish_create(broadcast = true, op_ctx = op_ctx)
  self

proc init*(
    T: type Zen,
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): T =
  ctx.setup_op_ctx
  T(flags: flags).defaults(ctx, id, op_ctx)

proc init*(
    _: type,
    T: type[string],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Zen[string, string] =
  ctx.setup_op_ctx
  result = Zen[string, string](flags: flags).defaults(ctx, id, op_ctx)

proc init*(
    _: type Zen,
    T: type[ref | object | array | SomeOrdinal | SomeNumber],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Zen[T, T] =
  ctx.setup_op_ctx
  result = Zen[T, T](flags: flags).defaults(ctx, id, op_ctx)

proc init*[T: ref | object | tuple | array | SomeOrdinal | SomeNumber | string | ptr](
    _: type Zen,
    tracked: T,
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Zen[T, T] =
  ctx.setup_op_ctx
  var self = Zen[T, T](flags: flags).defaults(ctx, id, op_ctx)

  mutate(op_ctx):
    self.tracked = tracked
  result = self

proc init*[O](
    _: type Zen,
    tracked: set[O],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Zen[set[O], O] =
  ctx.setup_op_ctx
  var self = Zen[set[O], O](flags: flags).defaults(ctx, id, op_ctx)

  mutate(op_ctx):
    self.tracked = tracked
  result = self

proc init*[K, V](
    _: type Zen,
    tracked: Table[K, V],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): ZenTable[K, V] =
  ctx.setup_op_ctx
  var self = ZenTable[K, V](flags: flags).defaults(ctx, id, op_ctx)

  mutate(op_ctx):
    self.tracked = tracked
  result = self

proc init*[O](
    _: type Zen,
    tracked: seq[O],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Zen[seq[O], O] =
  ctx.setup_op_ctx
  var self = Zen[seq[O], O](flags: flags).defaults(ctx, id, op_ctx)

  mutate(op_ctx):
    self.tracked = tracked
  result = self

proc init*[O](
    _: type Zen,
    T: type seq[O],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Zen[seq[O], O] =
  ctx.setup_op_ctx
  result = Zen[seq[O], O](flags: flags).defaults(ctx, id, op_ctx)

proc init*[O](
    _: type Zen,
    T: type set[O],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Zen[set[O], O] =
  ctx.setup_op_ctx
  result = Zen[set[O], O](flags: flags).defaults(ctx, id, op_ctx)

proc init*[K, V](
    _: type Zen,
    T: type Table[K, V],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): Zen[Table[K, V], Pair[K, V]] =
  ctx.setup_op_ctx
  result = Zen[Table[K, V], Pair[K, V]](flags: flags).defaults(ctx, id, op_ctx)

proc init*(
    _: type Zen,
    K, V: type,
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): ZenTable[K, V] =
  ctx.setup_op_ctx
  result = ZenTable[K, V](flags: flags).defaults(ctx, id, op_ctx)

proc zen_init_private*[K, V](
    tracked: seq[(K, V)],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
): ZenTable[K, V] =
  ctx.setup_op_ctx
  result = Zen.init(
    tracked.to_table, flags = flags, ctx = ctx, id = id, op_ctx = op_ctx
  )

proc init*[T, O](
    self: var Zen[T, O],
    flags = default_flags,
    ctx = ctx(),
    id = "",
    op_ctx = OperationContext(),
) =
  self = Zen[T, O].init(ctx = ctx, flags = flags, id = id, op_ctx = op_ctx)

proc init_zen_fields*[T: object or ref](
    self: T, flags = default_flags, ctx = ctx()
): T {.discardable.} =
  result = self
  for field in fields(self.deref):
    when field is Zen:
      field.init(ctx = ctx, flags = flags)

proc init_from*[T: object or ref](
    _: type T, src: T, ctx = ctx()
): T {.discardable.} =
  result = T()
  for src, dest in fields(src.deref, result.deref):
    when dest is Zen:
      dest = ctx[src]

macro `~`*(body: untyped): untyped =
  var args = body
  if body.kind == nnk_tuple_constr:
    args = new_nim_node(nnk_arg_list, body)
    body.copy_children_to(args)

  result = quote:
    when compiles(value(`args`)):
      value(`args`)
    elif compiles(zen_init_private(`args`)):
      zen_init_private(`args`)
    else:
      Zen.init(`args`)

macro bootstrap*(_: type Zen): untyped =
  result = new_stmt_list()
  for initializer in initializers:
    result.add initializer
