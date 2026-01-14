import std/[tables, sugar, unittest]
import pkg/[flatty, chronicles, pretty]
import model_citizen
import model_citizen/[types, components/type_registry]
from std/times import init_duration

proc run*() =
  type
    Unit = ref object of RootObj
      id: string

    Build = ref object of Unit
      build_stuff: string

    Bot = ref object of Unit
      bot_stuff: string

  Zen.register(Build, false)
  Zen.register(Bot, false)

  test "object publish inheritance":
    var
      ctx1 = ZenContext.init(id = "ctx1")
      ctx2 = ZenContext.init(id = "ctx2")
      build = Build(id: "some_build", build_stuff: "asdf")
      bot = Bot(id: "some_bot", bot_stuff: "wasd")
      units1 = ZenSeq[Unit].init(id = "units", ctx = ctx1)
      units2 = ZenSeq[Unit].init(id = "units", ctx = ctx2)

    ctx2.subscribe(ctx1)

    units1 += build
    units1 += bot

    ctx2.tick

    check units1.len == 2
    check units1[0] of Build
    check units1[1] of Bot

    check units2.len == 2
    check units2[0] of Build
    check units2[1] of Bot

  test "object mass assign inheritance":
    var
      ctx1 = ZenContext.init(id = "ctx1")
      ctx2 = ZenContext.init(id = "ctx2")
      build = Build(id: "some_build", build_stuff: "asdf")
      bot = Bot(id: "some_bot", bot_stuff: "wasd")
      units1 = ZenSeq[Unit].init(id = "units", ctx = ctx1)
      units2 = ZenSeq[Unit].init(id = "units", ctx = ctx2)

    ctx2.subscribe(ctx1)

    var units: seq[Unit]
    units.add build
    units.add bot

    units1.value = units

    ctx2.tick

    check units1.len == 2
    check units1[0] of Build
    check units1[1] of Bot

    check units2.len == 2
    check units2[0] of Build
    check units2[1] of Bot

  test "object publish on subscribe inheritance":
    var
      ctx1 = ZenContext.init(id = "ctx1")
      ctx2 = ZenContext.init(id = "ctx2")
      build = Build(id: "some_build", build_stuff: "asdf")
      bot = Bot(id: "some_bot", bot_stuff: "wasd")
      units1 = ZenSeq[Unit].init(id = "units", ctx = ctx1)
      units2 = ZenSeq[Unit].init(id = "units", ctx = ctx2)

    units1 += build
    units1 += bot

    ctx2.subscribe(ctx1)

    check units1.len == 2
    check units1[0] of Build
    check units1[1] of Bot

    check units2.len == 2
    check units2[0] of Build
    check units2[1] of Bot

  test "no sync objects are created remotely, but their value doesn't sync":
    var
      flags = {TrackChildren}
      ctx1 = ZenContext.init(id = "ctx1")
      ctx2 = ZenContext.init(id = "ctx2")
      a = ZenValue[string].init(id = "test1", ctx = ctx1, flags = flags)
      b = ZenValue[string].init(id = "test1", ctx = ctx2, flags = flags)
      c = ZenValue[string].init(id = "test2", ctx = ctx1, flags = flags)
      d: ZenValue[string]

    check "test1" in ctx2
    check "test2" notin ctx2

    a.value = "fizz"
    c.value = "buzz"

    ctx2.subscribe(ctx1)

    check "test2" in ctx2

    d = d.type()(ctx2["test2"])

    check a.value == "fizz"
    check c.value == "buzz"
    check b.value == ""
    check d.value == ""

    b.value = "hello"
    d.value = "world"

    check a.value == "fizz"
    check b.value == "hello"
    check c.value == "buzz"
    check d.value == "world"

  test "bulk assign seq triggers multiple callbacks on both sides":
    # Test that .value= on a seq triggers callbacks for each changed item
    var
      ctx1 = ZenContext.init(id = "ctx1")
      ctx2 = ZenContext.init(id = "ctx2")
      seq1 = ZenSeq[string].init(id = "seq", ctx = ctx1)
      seq2 = ZenSeq[string].init(id = "seq", ctx = ctx2)

    ctx2.subscribe(ctx1)

    var ctx1_added = 0
    var ctx2_added = 0

    seq1.changes:
      if added:
        inc ctx1_added

    seq2.changes:
      if added:
        inc ctx2_added

    # Bulk assign 5 items
    seq1.value = @["a", "b", "c", "d", "e"]

    # Verify ctx1 got 5 callbacks (one per item)
    check ctx1_added == 5

    # Sync to ctx2
    ctx2.tick

    # Verify ctx2 also got 5 callbacks
    check ctx2_added == 5

    # Verify data is correct on both sides
    check seq1.value == @["a", "b", "c", "d", "e"]
    check seq2.value == @["a", "b", "c", "d", "e"]

  test "bulk assign table triggers multiple callbacks on both sides":
    var
      ctx1 = ZenContext.init(id = "ctx1")
      ctx2 = ZenContext.init(id = "ctx2")
      table1 = ZenTable[string, int].init(id = "table", ctx = ctx1)
      table2 = ZenTable[string, int].init(id = "table", ctx = ctx2)

    ctx2.subscribe(ctx1)

    var ctx1_added = 0
    var ctx2_added = 0

    table1.changes:
      if added:
        inc ctx1_added

    table2.changes:
      if added:
        inc ctx2_added

    # Bulk assign table with 4 entries
    table1.value = {"one": 1, "two": 2, "three": 3, "four": 4}.toTable

    check ctx1_added == 4

    ctx2.tick

    check ctx2_added == 4
    check table1.value == {"one": 1, "two": 2, "three": 3, "four": 4}.toTable
    check table2.value == {"one": 1, "two": 2, "three": 3, "four": 4}.toTable

  test "bulk assign set triggers multiple callbacks on both sides":
    var
      ctx1 = ZenContext.init(id = "ctx1")
      ctx2 = ZenContext.init(id = "ctx2")
      set1 = ZenSet[char].init(id = "set", ctx = ctx1)
      set2 = ZenSet[char].init(id = "set", ctx = ctx2)

    ctx2.subscribe(ctx1)

    var ctx1_added = 0
    var ctx2_added = 0

    set1.changes:
      if added:
        inc ctx1_added

    set2.changes:
      if added:
        inc ctx2_added

    # Bulk assign set with 3 items
    set1.value = {'x', 'y', 'z'}

    check ctx1_added == 3

    ctx2.tick

    check ctx2_added == 3
    check set1.value == {'x', 'y', 'z'}
    check set2.value == {'x', 'y', 'z'}

when is_main_module:
  Zen.bootstrap
  run()
