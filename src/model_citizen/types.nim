import model_citizen/[deps]
import pkg/[serialization, json_serialization]

type
  ZID* = uint16

  ZenFlags* = enum
    TrackChildren
    SyncLocal
    SyncRemote
    SyncAllNoOverwrite

  ChangeKind* = enum
    Created
    Added
    Removed
    Modified
    Touched
    Closed

  MessageKind* = enum
    Blank
    Create
    Destroy
    Assign
    Unassign
    Touch
    Subscribe
    Packed

  BaseChange* = ref object of RootObj
    changes*: set[ChangeKind]
    field_name*: string
    triggered_by*: seq[BaseChange]
    triggered_by_type*: string
    type_name*: string

  OperationContext = object
    source*: HashSet[string]
    when defined(zen_trace):
      trace*: string

  PackedMessageOperation* =
    tuple[kind: MessageKind, ref_id: int, change_object_id: string, obj: string]

  IdMapping* = tuple[short_id: uint8, full_id: string]

  Message = object
    kind*: MessageKind
    object_id*: string
    change_object_id*: string
    type_id*: int
    ref_id*: int
    obj*: string
    source*: seq[uint8]  # Short IDs for wire format (Remote)
    source_set*: HashSet[string]  # Full source for internal use (Local) - not serialized
    id_mappings*: seq[IdMapping]  # New mappings for unknown IDs
    flags*: set[ZenFlags]
    when defined(zen_trace):
      trace*: string
      id*: int
      debug*: string

  CreateInitializer = proc(
    bin: string,
    ctx: ZenContext,
    id: string,
    flags: set[ZenFlags],
    op_ctx: OperationContext,
  )

  Change*[O] = ref object of BaseChange
    item*: O

  Pair[K, V] = object
    key*: K
    value*: V

  CountedRef = object
    obj*: ref RootObj
    references*: HashSet[string]

  RegisteredType = object
    tid*: int
    stringify*: proc(self: ref RootObj): string {.no_side_effect.}
    parse*:
      proc(ctx: ZenContext, clone_from: string): ref RootObj {.no_side_effect.}

  SubscriptionKind* = enum
    Blank
    Local
    Remote

  Subscription* = ref object
    ctx_id*: string
    # Short ID mappings for this connection
    next_short_id*: uint8  # Next available short ID to assign
    id_to_short*: Table[string, uint8]  # full context ID → short ID
    short_to_id*: Table[uint8, string]  # short ID → full context ID
    case kind*: SubscriptionKind
    of Local:
      chan*: Chan[Message]
      chan_buffer*: seq[Message]
    of Remote:
      connection*: Connection
      last_sent_time*: float64
    else:
      discard

  ZenContext* = ref object
    id*: string
    changed_callback_zid: ZID
    last_id: int
    close_procs: Table[ZID, proc() {.gcsafe.}]
    objects*: OrderedTable[string, ref ZenBase]
    objects_need_packing*: bool
    ref_pool: Table[string, CountedRef]
    subscribers*: seq[Subscription]
    chan: Chan[Message]
    freeable_refs: Table[string, MonoTime]
    last_msg_id: Table[string, int]
    last_received_id: Table[string, int]
    reactor*: Reactor
    remote_messages: seq[netty.Message]
    blocking_recv: bool
    buffer: bool
    min_recv_duration: Duration
    max_recv_duration: Duration
    subscribing*: bool
    value_initializers*: seq[proc() {.gcsafe.}]
    dead_connections: seq[Connection]
    unsubscribed*: seq[string]
    metrics_label*: string
    free_queue*: seq[string]
    last_keepalive_tick*: float64
    bytes_sent*: int
    bytes_received*: int
    when defined(zen_debug_messages):
      messages_sent*: int
      messages_received*: int
      obj_bytes_sent*: int
      obj_bytes_received*: int
      pre_compression_bytes*: int  # Total bytes before snappy compression
      messages_by_kind*: array[MessageKind, int]
      obj_bytes_sent_by_kind*: array[MessageKind, int]
      obj_bytes_recv_by_kind*: array[MessageKind, int]
    when defined(dump_zen_objects):
      dump_at*: MonoTime
      counts*: array[MessageKind, int]

  ZenBase* = object of RootObj
    id*: string
    destroyed*: bool
    link_zid: ZID
    paused_zids: set[ZID]
    bound_zids: seq[ZID]
    flags*: set[ZenFlags]
    build_message: proc(
      self: ref ZenBase, change: BaseChange, id: string, trace: string
    ): Message {.gcsafe.}

    publish_create: proc(
      sub = Subscription(), broadcast = false, op_ctx = OperationContext()
    ) {.gcsafe.}

    change_receiver:
      proc(self: ref ZenBase, msg: Message, op_ctx: OperationContext) {.gcsafe.}

    ctx*: ZenContext

  ChangeCallback[O] = proc(changes: seq[Change[O]]) {.gcsafe.}

  ZenObject[T, O] = object of ZenBase
    changed_callbacks: OrderedTable[ZID, ChangeCallback[O]]
    tracked: T

  Zen*[T, O] = ref object of ZenObject[T, O]

  ZenTable*[K, V] = Zen[Table[K, V], Pair[K, V]]
  ZenSeq*[T] = Zen[seq[T], T]
  ZenSet*[T] = Zen[set[T], T]
  ZenValue*[T] = Zen[T, T]

const default_flags* = {SyncLocal, SyncRemote}

template zen_ignore*() {.pragma.}

proc write_value*[T](w: var JsonWriter, self: set[T]) =
  write_value(w, self.to_seq)

proc write_value*(w: var JsonWriter, self: ZenContext) =
  write_value(w, self.id)

proc write_value*(w: var JsonWriter, self: Subscription) =
  write_value(w, (ctx_id: self.ctx_id, kind: self.kind))

# Custom flatty serializers for Message to skip source_set (internal use only)
proc to_flatty*(s: var string, msg: Message) =
  s.to_flatty msg.kind
  s.to_flatty msg.object_id
  s.to_flatty msg.change_object_id
  s.to_flatty msg.type_id
  s.to_flatty msg.ref_id
  s.to_flatty msg.obj
  s.to_flatty msg.source
  # Skip source_set - internal use only
  s.to_flatty msg.id_mappings
  s.to_flatty msg.flags
  when defined(zen_trace):
    s.to_flatty msg.trace
    s.to_flatty msg.id
    s.to_flatty msg.debug

proc from_flatty*(s: string, i: var int, msg: var Message) =
  s.from_flatty(i, msg.kind)
  s.from_flatty(i, msg.object_id)
  s.from_flatty(i, msg.change_object_id)
  s.from_flatty(i, msg.type_id)
  s.from_flatty(i, msg.ref_id)
  s.from_flatty(i, msg.obj)
  s.from_flatty(i, msg.source)
  # source_set not in wire format
  s.from_flatty(i, msg.id_mappings)
  s.from_flatty(i, msg.flags)
  when defined(zen_trace):
    s.from_flatty(i, msg.trace)
    s.from_flatty(i, msg.id)
    s.from_flatty(i, msg.debug)
