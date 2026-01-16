import std/sets
import ed/types {.all.}
import ed/components/private/global_state
const chronicles_enabled* {.strdefine.} = "off"

when chronicles_enabled == "on":
  import pkg/chronicles
  export chronicles

  # Format types for concise logging
  chronicles.format_it(EdContext): it.id
  chronicles.format_it(Subscription): $it.kind & " sub for " & it.ctx_id
  chronicles.format_it(OperationContext):
    if it.source.len == 0:
      "(no source)"
    else:
      "source=" & $it.source
  chronicles.format_it(Message):
    $it.kind & " " & it.object_id & " obj=" & $it.obj.len & "b"

  # Must be explicitly called from generic procs due to
  # https://github.com/status-im/nim-chronicles/issues/121
  template log_defaults*(log_topics = "ed") =
    log_scope:
      topics = log_topics
      thread_ctx = active_ctx.id

else:
  # Don't include chronicles unless it's specifically enabled.
  # Use of chronicles in a module requires that the calling module also import
  # chronicles, due to https://github.com/nim-lang/Nim/issues/11225.
  # This has been fixed in Nim, so it may be possible to fix in chronicles.
  template trace*(msg: string, _: varargs[untyped]) =
    discard

  template notice*(msg: string, _: varargs[untyped]) =
    discard

  template debug*(msg: string, _: varargs[untyped]) =
    discard

  template info*(msg: string, _: varargs[untyped]) =
    discard

  template warn*(msg: string, _: varargs[untyped]) =
    discard

  template error*(msg: string, _: varargs[untyped]) =
    discard

  template fatal*(msg: string, _: varargs[untyped]) =
    discard

  template log_scope*(body: untyped) =
    discard

  template log_defaults*(log_topics = "") =
    discard
