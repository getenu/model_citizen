import std/[tables, sugar, unittest]
import pkg/[flatty, chronicles, pretty]
import ed
from std/times import init_duration

const recv_duration = init_duration(milliseconds = 10)

type Vector3 = array[3, float]

proc run*() =
  test "4 way sync":
    var
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(
        id = "ctx2",
        listen_address = "127.0.0.1",
        min_recv_duration = recv_duration,
        blocking_recv = true,
      )
      ctx3 = EdContext.init(
        id = "ctx3", min_recv_duration = recv_duration, blocking_recv = true
      )
      ctx4 = EdContext.init(id = "ctx4")

    ctx2.subscribe(ctx1)
    ctx3.subscribe(ctx4)
    ctx3.subscribe "127.0.0.1",
      callback = proc() =
        ctx2.tick(blocking = false)

    var
      a = EdValue[string].init(id = "test1", ctx = ctx1)
      b = EdValue[string].init(id = "test1", ctx = ctx2)
      c = EdValue[string].init(id = "test1", ctx = ctx3)
      d = EdValue[string].init(id = "test1", ctx = ctx4)

    ctx1.tick
    ctx2.tick

    a.value = "set"
    ctx1.tick
    ctx2.tick
    ctx3.tick
    ctx4.tick
    check d.value == "set"

    ctx2.close

  test "trigger changes on subscribe":
    var
      count = 0
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(
        id = "ctx2",
        listen_address = "127.0.0.1",
        min_recv_duration = recv_duration,
        blocking_recv = true,
      )
      ctx3 = EdContext.init(
        id = "ctx3", min_recv_duration = recv_duration, blocking_recv = true
      )
      ctx4 = EdContext.init(id = "ctx4")

    var
      a = Ed.init(@["a1", "a2"], id = "test2", ctx = ctx1)
      b = Ed.init(@["b1", "b2"], id = "test2", ctx = ctx2)
      c = Ed.init(@["c1", "c2"], id = "test2", ctx = ctx3)
      d = Ed.init(@["d1", "d2"], id = "test2", ctx = ctx4)

    d.changes:
      if added:
        inc count

    ctx2.subscribe(ctx1)
    ctx3.subscribe(ctx4)

    ctx1.tick

    check a.value == @["a1", "a2"]
    check b.value == @["a1", "a2"]

    ctx4.tick
    ctx3.subscribe "127.0.0.1",
      callback = proc() =
        ctx2.tick(blocking = false)

    ctx4.tick

    check count == 2
    check a.len == 2

    check a.value == @["a1", "a2"]
    check b.value == @["a1", "a2"]
    check c.value == @["a1", "a2"]
    check d.value == @["a1", "a2"]

    ctx2.close

  test "nested collection":
    type Unit = object
      code: EdValue[string]

    var
      count = 0
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(
        id = "ctx2",
        listen_address = "127.0.0.1",
        min_recv_duration = recv_duration,
        blocking_recv = true,
      )
      ctx3 = EdContext.init(
        id = "ctx3", min_recv_duration = recv_duration, blocking_recv = true
      )
      ctx4 = EdContext.init(id = "ctx4")

    var
      a = Ed.init(@["a1", "a2"], id = "test2", ctx = ctx1)
      b = Ed.init(@["b1", "b2"], id = "test2", ctx = ctx2)
      c = Ed.init(@["c1", "c2"], id = "test2", ctx = ctx3)
      d = Ed.init(@["d1", "d2"], id = "test2", ctx = ctx4)

    d.changes:
      if added:
        inc count

    ctx2.subscribe(ctx1)
    ctx3.subscribe(ctx4)

    ctx1.tick

    check a.value == @["a1", "a2"]
    check b.value == @["a1", "a2"]

    ctx4.tick
    ctx3.subscribe "127.0.0.1",
      callback = proc() =
        ctx2.tick(blocking = false)

    ctx4.tick

    check count == 2
    check a.len == 2

    check a.value == @["a1", "a2"]
    check b.value == @["a1", "a2"]
    check c.value == @["a1", "a2"]
    check d.value == @["a1", "a2"]

    ctx2.close

  test "Vector3 array network sync":
    var
      ctx1 = EdContext.init(id = "ctx1")
      ctx2 = EdContext.init(
        id = "ctx2",
        listen_address = "127.0.0.1",
        min_recv_duration = recv_duration,
        blocking_recv = true,
      )

    ctx2.subscribe(ctx1)

    # Create Vector3 value and verify it creates EdValue not EdSeq
    var vec = Vector3([1.0, 2.0, 3.0])
    var v1 = Ed.init(vec, id = "vector", ctx = ctx1)
    
    # Verify type - this ensures our fix worked
    check v1 is EdValue[Vector3]
    check v1.value == vec

    ctx1.tick
    ctx2.tick

    # Test that it synced over network
    var v2 = EdValue[Vector3](ctx2["vector"])
    check v2.value == vec

    # Test mutation sync
    v1.value = Vector3([4.0, 5.0, 6.0])
    ctx1.tick
    ctx2.tick
    check v2.value == Vector3([4.0, 5.0, 6.0])

    ctx2.close

when is_main_module:
  Ed.bootstrap
  run()
