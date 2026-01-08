import
  std/[importutils, tables, sets, sequtils, algorithm, intsets, locks, math, times]

import pkg/threading/channels {.all.}
import pkg/[flatty, supersnappy]

import
  model_citizen/[core, types {.all.}],
  model_citizen/zens/[contexts, private, initializers {.all.}]

import model_citizen/components/[private/global_state]

import ./type_registry

var flatty_ctx {.threadvar.}: ZenContext

type FlatRef = tuple[tid: int, ref_id: string, item: string]

type ZenFlattyInfo = tuple[object_id: string, tid: int]

privileged

proc `$`*(self: Subscription): string =
  \"{self.kind} subscription for {self.ctx_id}"

proc tick*(
  self: ZenContext,
  messages = int.high,
  max_duration = self.max_recv_duration,
  min_duration = self.min_recv_duration,
  blocking = self.blocking_recv,
  poll = true,
) {.gcsafe.}

proc to_flatty*[T: ref RootObj](s: var string, x: T) =
  when x is ref ZenBase:
    s.to_flatty not ?x
    if ?x:
      s.to_flatty ZenFlattyInfo((x.id, x.type.tid))
  else:
    var registered_type: RegisteredType
    when compiles(x.id):
      if ?x and x.lookup_type(registered_type):
        s.to_flatty true
        let obj: FlatRef = (
          tid: registered_type.tid,
          ref_id: x.ref_id,
          item: registered_type.stringify(x),
        )

        flatty.to_flatty(s, obj)
        return
    s.to_flatty false
    s.to_flatty not ?x
    if ?x:
      flatty.to_flatty(s, x)

proc from_flatty*[T: ref RootObj](s: string, i: var int, value: var T) =
  privileged

  when value is ref ZenBase:
    var is_nil: bool
    s.from_flatty(i, is_nil)
    if not is_nil:
      var info: ZenFlattyInfo
      s.from_flatty(i, info)
      # :(
      if info.object_id in flatty_ctx:
        value = value.type()(flatty_ctx.objects[info.object_id])
  else:
    var is_registered: bool
    s.from_flatty(i, is_registered)
    if is_registered:
      var val: FlatRef
      flatty.from_flatty(s, i, val)

      if val.ref_id in flatty_ctx.ref_pool:
        value = value.type()(flatty_ctx.ref_pool[val.ref_id].obj)
      else:
        var registered_type: RegisteredType
        do_assert lookup_type(val.tid, registered_type)
        value = value.type()(registered_type.parse(flatty_ctx, val.item))
    else:
      var is_nil: bool
      s.from_flatty(i, is_nil)
      if not is_nil:
        value = value.type()()
        value[] = flatty.from_flatty(s, value[].type)

proc to_flatty*(s: var string, x: proc) =
  discard

proc from_flatty*(s: string, i: var int, p: proc) =
  discard

proc to_flatty*(s: var string, p: ptr) =
  s.to_flatty(cast[int](p))

proc to_flatty*(s: var string, p: pointer) =
  discard

proc from_flatty*(s: string, i: var int, p: pointer) =
  discard

proc from_flatty*(s: string, i: var int, p: var ptr) =
  var val: int
  s.from_flatty(i, val)
  p = cast[p.type](val)

proc from_flatty*(bin: string, T: type, ctx: ZenContext): T =
  flatty_ctx = ctx
  result = flatty.from_flatty(bin, T)

proc send_or_buffer(sub: Subscription, msg: sink Message, buffer: bool) =
  if buffer and (sub.chan_buffer.len > 0 or sub.chan.full):
    sub.chan_buffer.add msg
  else:
    sub.chan.send(msg)

proc flush_buffers*(self: ZenContext) =
  for sub in self.subscribers:
    if sub.kind == Local and sub.chan_buffer.len > 0 and not sub.chan.full:
      let buffer = sub.chan_buffer
      sub.chan_buffer.set_len(0)
      for msg in buffer:
        sub.send_or_buffer(msg, true)

proc send*(
    self: ZenContext,
    sub: Subscription,
    msg: sink Message,
    op_ctx = OperationContext(),
    flags = default_flags,
) =
  log_defaults("model_citizen networking")
  sent_message_counter.inc(label_values = [self.metrics_label])
  when defined(zen_trace):
    if sub.ctx_id notin self.last_msg_id:
      self.last_msg_id[sub.ctx_id] = 1
    else:
      self.last_msg_id[sub.ctx_id] += 1
    msg.id = self.last_msg_id[sub.ctx_id]

  when defined(dump_zen_objects):
    self.counts[msg.kind] += 1

  debug "sending message", msg

  msg.source = op_ctx.source
  if msg.source == "":
    msg.source = self.id

  var msg = msg
  if sub.kind == Local and SyncLocal in flags:
    sub.send_or_buffer(msg, self.buffer)
  elif sub.kind == Local and SyncAllNoOverwrite in flags:
    msg.obj = ""
    sub.send_or_buffer(msg, self.buffer)
  elif sub.kind == Remote and SyncRemote in flags:
    let data = msg.to_flatty.compress
    self.bytes_sent += data.len
    self.reactor.send(sub.connection, data)
    sub.last_sent_time = epoch_time()
  elif sub.kind == Remote and SyncAllNoOverwrite in flags:
    msg.obj = ""
    let data = msg.to_flatty.compress
    self.bytes_sent += data.len
    self.reactor.send(sub.connection, data)
    sub.last_sent_time = epoch_time()

proc publish_destroy*[T, O](self: Zen[T, O], op_ctx: OperationContext) =
  privileged
  log_defaults("model_citizen publishing")

  debug "publishing destroy", zen_id = self.id
  for sub in self.ctx.subscribers:
    if sub.ctx_id notin op_ctx.source:
      when defined(zen_trace):
        self.ctx.send(
          sub,
          Message(
            kind: Destroy,
            object_id: self.id,
            trace: \"{get_stack_trace()}\n\nop:\n{op_ctx.trace}",
          ),
          op_ctx,
          self.flags,
        )
      else:
        self.ctx.send(
          sub, Message(kind: Destroy, object_id: self.id), op_ctx, self.flags
        )

  self.ctx.tick_reactor

proc pack_messages(msgs: seq[Message]): seq[Message] =
  if msgs.len > 1:
    var packed_msg =
      Message(kind: Packed, source: msgs[0].source, flags: msgs[0].flags)
    var ops: seq[PackedMessageOperation]

    for msg in msgs:
      if msg.object_id != "":
        assert packed_msg.object_id == "" or
          packed_msg.object_id == msg.object_id

        packed_msg.object_id = msg.object_id
      if msg.type_id != 0:
        assert packed_msg.type_id == 0 or packed_msg.type_id == msg.type_id

        packed_msg.type_id = msg.type_id
      ops.add (msg.kind, msg.ref_id, msg.change_object_id, msg.obj)

    packed_msg.obj = ops.to_flatty
    result = @[packed_msg]
  else:
    result = msgs

proc publish_changes*[T, O](
    self: Zen[T, O], changes: seq[Change[O]], op_ctx: OperationContext
) =
  privileged
  log_defaults("model_citizen publishing")
  debug "publish_changes", ctx = self.ctx, op_ctx
  if self.ctx.subscribers.len > 0:
    var msgs: seq[Message]
    let id = self.id
    assert id in self.ctx
    let obj = self.ctx.objects[id]

    for change in changes:
      if [Added, Removed, Created, Touched].any_it(it in change.changes):
        if Removed in change.changes and Modified in change.changes:
          # An assign will trigger both an assign and an unassign on the other
          # side. We only want to send a Removed message when an item is
          # removed from a collection.
          debug "skipping changes"
          continue
        let trace =
          when defined(zen_trace):
            \"{get_stack_trace()}\n\nop:\n{op_ctx.trace}"
          else:
            ""
        msgs.add obj.build_message(obj, change, id, trace)

    msgs = pack_messages(msgs)

    for sub in self.ctx.subscribers:
      if sub.ctx_id notin op_ctx.source:
        for msg in msgs:
          self.ctx.send(sub, msg, op_ctx, self.flags)

    self.ctx.tick_reactor

proc add_subscriber*(
    self: ZenContext,
    sub: Subscription,
    push_all: bool,
    remote_objects: HashSet[string],
) =
  self.pack_objects
  debug "adding subscriber", sub
  self.subscribers.add sub
  for id in self.objects.keys.to_seq.reversed:
    if id notin remote_objects or push_all:
      debug "sending object on subscribe",
        from_ctx = self.id, to_ctx = sub.ctx_id, zen_id = id

      let zen = self.objects[id]
      zen.publish_create sub
    else:
      debug "not sending object because remote ctx already has it",
        from_ctx = self.id, to_ctx = sub.ctx_id, zen_id = id

proc unsubscribe*(self: ZenContext, sub: Subscription) =
  if sub.kind == Remote:
    self.reactor.disconnect(sub.connection)
  else:
    # ???
    discard
  self.subscribers.delete self.subscribers.find(sub)
  self.unsubscribed.add sub.ctx_id

proc process_value_initializers(self: ZenContext) =
  debug "running deferred initializers", ctx = self.id
  for initializer in self.value_initializers:
    initializer()
  self.value_initializers = @[]

proc subscribe*(self: ZenContext, ctx: ZenContext, bidirectional = true) =
  privileged
  debug "local subscribe", ctx = self.id
  self.pack_objects
  var remote_objects: HashSet[string]
  for id in self.objects.keys:
    remote_objects.incl id
  self.subscribing = true
  ctx.add_subscriber(
    Subscription(kind: Local, chan: self.chan, ctx_id: self.id),
    push_all = bidirectional,
    remote_objects,
  )

  self.tick(blocking = false, min_duration = Duration.default)
  self.subscribing = false
  self.process_value_initializers

  if bidirectional:
    ctx.subscribe(self, bidirectional = false)

proc subscribe*(
    self: ZenContext,
    address: string,
    bidirectional = true,
    callback: proc() {.gcsafe.} = nil,
) =
  # callback param is a hack to allow testing networked contexts on the same
  # thread. Not meant to be used in non-test code
  var address = address
  var port = 9632

  debug "remote subscribe", address
  if not ?self.reactor:
    self.reactor = new_reactor()
  self.subscribing = true
  let parts = address.split(":")
  assert parts.len in [1, 2],
    "subscription address must be in the format " &
      "`hostname` or `hostname:port`"

  if parts.len == 2:
    address = parts[0]
    port = parts[1].parse_int

  let connection = self.reactor.connect(address, port)
  self.send(
    Subscription(kind: Remote, ctx_id: "temp", connection: connection, last_sent_time: epoch_time()),
    Message(kind: Subscribe),
  )

  var ctx_id = ""
  var received_objects: HashSet[string]
  var finished = false
  var remote_objects: HashSet[string]
  while not finished:
    self.reactor.tick
    self.dead_connections &= self.reactor.dead_connections
    for conn in self.dead_connections:
      if connection == conn:
        raise ConnectionError.init(\"Unable to connect to {address}:{port}")

    for msg in self.reactor.messages:
      self.bytes_received += msg.data.len
      if msg.data.starts_with("ACK:"):
        if bidirectional:
          let pieces = msg.data.split(":")
          ctx_id = pieces[1]
          for id in pieces[2 ..^ 1]:
            remote_objects.incl id

        finished = true
      else:
        self.remote_messages &= msg
    if callback != nil:
      callback()

  self.tick(poll = false)
  self.subscribing = false
  self.process_value_initializers

  if bidirectional:
    let sub = Subscription(kind: Remote, connection: connection, ctx_id: ctx_id, last_sent_time: epoch_time())

    self.add_subscriber(sub, push_all = false, remote_objects)

  self.tick(blocking = false)

proc process_message(self: ZenContext, msg: Message) =
  privileged
  log_defaults("model_citizen publishing")
  assert self.id notin msg.source

  received_message_counter.inc(label_values = [self.metrics_label])
  # when defined(zen_trace):
  #   let src = self.name & "-" & msg.source
  #   if src in self.last_received_id:
  #     if msg.id != self.last_received_id[src] + 1:
  #       raise_check &"src={src} msg.id={msg.id} " &
  #           &"last={self.last_received_id[src]}. Should be msg.id - 1"
  #   self.last_received_id[src] = msg.id
  debug "receiving", msg, topics = "networking"

  if msg.kind == Packed:
    let ops = msg.obj.from_flatty(seq[PackedMessageOperation])
    for op in ops:
      var new_msg = Message(
        kind: op.kind,
        object_id: msg.object_id,
        type_id: msg.type_id,
        ref_id: op.ref_id,
        change_object_id: op.change_object_id,
        obj: op.obj,
        flags: msg.flags,
        source: msg.source,
      )

      self.process_message(new_msg)
  elif msg.kind == Create:
    {.gcsafe.}:
      if msg.type_id notin type_initializers:
        print msg
        fail \"No type initializer for type {msg.type_id}"

    {.gcsafe.}:
      let fn = type_initializers[msg.type_id]
      fn(
        msg.obj,
        self,
        msg.object_id,
        msg.flags,
        OperationContext.init(source = msg, ctx = self),
      )
      # :(
  elif msg.kind != Blank:
    if msg.object_id notin self:
      # :( this should throw an error
      debug "missing object", object_id = msg.object_id
      return
    let obj = self.objects[msg.object_id]
    obj.change_receiver(
      obj, msg, op_ctx = OperationContext.init(source = msg, ctx = self)
    )
  else:
    fail "Can't recv a blank message"

proc untrack*[T, O](self: Zen[T, O], zid: ZID) =
  privileged
  log_defaults
  assert self.valid

  # :(
  if zid in self.changed_callbacks:
    let callback = self.changed_callbacks[zid]
    if zid notin self.paused_zids:
      callback(@[Change.init(O, {Closed})])
    self.ctx.close_procs.del(zid)
    debug "removing close proc", zid
    self.changed_callbacks.del(zid)
  else:
    error "no change callback for zid", zid = zid

proc track*[T, O](
    self: Zen[T, O], callback: proc(changes: seq[Change[O]]) {.gcsafe.}
): ZID {.discardable.} =
  privileged
  log_defaults

  assert self.valid
  inc self.ctx.changed_callback_zid
  let zid = self.ctx.changed_callback_zid
  self.changed_callbacks[zid] = callback
  debug "adding close proc", zid
  self.ctx.close_procs[zid] = proc() =
    self.untrack(zid)
  result = zid

proc track*[T, O](
    self: Zen[T, O],
    callback: proc(changes: seq[Change[O]], zid: ZID) {.gcsafe.},
): ZID {.discardable.} =
  assert self.valid
  var zid: ZID
  zid = self.track proc(changes: seq[Change[O]]) {.gcsafe.} =
    callback(changes, zid)

  result = zid

proc untrack_on_destroy*(self: ref ZenBase, zid: ZID) =
  self.bound_zids.add(zid)

proc tick*(
    self: ZenContext,
    messages = int.high,
    max_duration = self.max_recv_duration,
    min_duration = self.min_recv_duration,
    blocking = self.blocking_recv,
    poll = true,
) {.gcsafe.} =
  ticks_counter.inc(label_values = [self.metrics_label])

  pressure_gauge.set(self.pressure, label_values = [self.metrics_label])
  object_pool_gauge.set(
    float self.objects.len, label_values = [self.metrics_label]
  )

  ref_pool_gauge.set(
    float self.ref_pool.len, label_values = [self.metrics_label]
  )

  buffer_gauge.set(
    float self.subscribers.map_it(
      if it.kind == Local: it.chan_buffer.len else: 0
    ).sum,
    label_values = [self.metrics_label],
  )

  chan_remaining_gauge.set(
    float self.chan.remaining, label_values = [self.metrics_label]
  )

  # Always try to send keepalives when booping
  self.tick_keepalives()

  var msg: Message
  self.unsubscribed = @[]
  var count = 0
  self.free_refs
  let timeout =
    if not ?max_duration:
      MonoTime.high
    else:
      get_mono_time() + max_duration
  let recv_until =
    if not ?min_duration:
      MonoTime.low
    else:
      get_mono_time() + min_duration

  self.flush_buffers
  while true:
    if poll:
      while get_mono_time() < timeout and self.chan.try_recv(msg):
        self.process_message(msg)
        inc count

    if ?self.reactor:
      if poll:
        self.tick_reactor

      let messages = self.remote_messages
      self.remote_messages = @[]

      for conn in self.dead_connections:
        let subs = self.subscribers
        for sub in subs:
          if sub.kind == Remote and sub.connection == conn:
            self.unsubscribe(sub)

      self.dead_connections = @[]

      for raw_msg in messages:
        inc count
        # Handle keepalive pings - just ignore them (receiving updates lastActiveTime in netty)
        if raw_msg.data == "PING":
          continue
        let msg = raw_msg.data.uncompress.from_flatty(Message, self)
        if msg.kind == Subscribe:
          var remote: HashSet[string]
          self.add_subscriber(
            Subscription(
              kind: Remote, connection: raw_msg.conn, ctx_id: msg.source, last_sent_time: epoch_time()
            ),
            push_all = true,
            remote,
          )

          self.pack_objects
          var objects = self.objects.keys.to_seq.join(":")

          let ack_data = "ACK:" & self.id & ":" & objects
          self.bytes_sent += ack_data.len
          self.reactor.send(raw_msg.conn, ack_data)
          sent_message_counter.inc(label_values = [self.metrics_label])
          self.reactor.tick
          self.dead_connections &= self.reactor.dead_connections
          for msg in self.reactor.messages:
            self.bytes_received += msg.data.len
          self.remote_messages &= self.reactor.messages
        else:
          self.process_message(msg)

    if poll == false or
        ((count > 0 or not blocking) and get_mono_time() > recv_until):
      break

template changes*[T, O](self: Zen[T, O], pause_me, body) =
  let zen = self
  make_discardable block:
    {.line.}:
      zen.track proc(changes: seq[Change[O]], zid {.inject.}: ZID) {.gcsafe.} =
        let pause_zid = if pause_me: zid else: 0
        zen.pause(pause_zid):
          for change {.inject.} in changes:
            template added(): bool =
              Added in change.changes

            template added(obj: O): bool =
              change.item == obj and added()

            template removed(): bool =
              Removed in change.changes

            template removed(obj: O): bool =
              change.item == obj and removed()

            template modified(): bool =
              Modified in change.changes

            template modified(obj: O): bool =
              change.item == obj and modified()

            template touched(): bool =
              Touched in change.changes

            template touched(obj: O): bool =
              change.item == obj and touched()

            template closed(): bool =
              Closed in change.changes

            {.line.}:
              body

template changes*[T, O](self: Zen[T, O], body) =
  changes(self, true, body)
