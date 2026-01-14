import std/[tables, intsets, locks]

import pkg/metrics
export inc, set

import model_citizen/types {.all.}

var active_ctx* {.threadvar.}: ZenContext

var local_type_registry* {.threadvar.}: Table[int, RegisteredType]
var processed_types* {.threadvar.}: IntSet
var raw_type_registry: Table[int, RegisteredType]
var global_type_registry* = addr raw_type_registry
var type_registry_lock*: Lock
type_registry_lock.init_lock

template with_lock*(body: untyped) =
  {.gcsafe.}:
    locks.with_lock(type_registry_lock):
      body

# Gauges for monitoring context state
declare_public_gauge pressure_gauge,
  "Thread channel pressure", name = "zen_pressure", labels = ["ctx"]

declare_public_gauge object_pool_gauge,
  "Object pool size", name = "zen_object_pool", labels = ["ctx"]

declare_public_gauge ref_pool_gauge,
  "Ref pool size", name = "zen_ref_pool", labels = ["ctx"]

declare_public_gauge chan_remaining_gauge,
  "Free channel slots", name = "zen_chan_remaining", labels = ["ctx"]

declare_public_gauge buffer_gauge,
  "Buffer size", name = "zen_channel_buffer", labels = ["ctx"]

# Message counters with kind/type breakdown
declare_public_counter sent_message_counter,
  "Messages sent", name = "zen_messages_sent", labels = ["ctx", "kind", "type"]

declare_public_counter received_message_counter,
  "Messages received", name = "zen_messages_received", labels = ["ctx", "kind", "type"]

declare_public_counter dropped_message_counter,
  "Messages dropped", name = "zen_dropped_messages", labels = ["ctx"]

declare_public_counter ticks_counter,
  "Ticks", name = "zen_ticks", labels = ["ctx"]

# Byte counters
declare_public_counter bytes_sent_counter,
  "Bytes sent (post-compression)", name = "zen_bytes_sent", labels = ["ctx"]

declare_public_counter bytes_received_counter,
  "Bytes received", name = "zen_bytes_received", labels = ["ctx"]

declare_public_counter obj_bytes_sent_counter,
  "Object payload bytes sent", name = "zen_obj_bytes_sent", labels = ["ctx", "kind", "type"]

declare_public_counter obj_bytes_received_counter,
  "Object payload bytes received", name = "zen_obj_bytes_received", labels = ["ctx", "kind", "type"]

declare_public_counter pre_compression_bytes_counter,
  "Bytes before compression", name = "zen_pre_compression_bytes", labels = ["ctx"]
