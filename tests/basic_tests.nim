import
  std/[
    tables, sequtils, sugar, macros, typetraits, sets, isolation, unittest,
    deques, importutils, monotimes, os
  ]
import pkg/[pretty, chronicles, netty]
import model_citizen
from std/times import init_duration
import model_citizen/[types {.all.}, zens {.all.}, zens/contexts {.all.}]

import model_citizen/components/type_registry

type Vector3 = array[3, float]

proc run*() =
  var change_count = 0
  proc count_changes(obj: auto): ZID {.discardable.} =
    obj.changes:
      change_count += 1

  template changes(expected_count: int, body) =
    change_count = 0
    body
    if change_count != expected_count:
      echo ast_to_str(body)
      echo "Expected ", expected_count, " changes. Got ", change_count

  template assert_changes[T, O](self: Zen[T, O], expect, body: untyped) =
    var expectations = expect.to_deque
    self.track proc(changes: seq[Change[O]]) {.gcsafe.} =
      for change in changes:
        let expectation = expectations.pop_first()
        if not (
          expectation[0] in change.changes and expectation[1] == change.item
        ):
          error "unsatisfied expectation", expectation
    body
    if expectations.len > 0:
      echo "unsatisfied expectations: ", expectations
      check false

  template local(body) =
    block local:
      debug "local run"
      var
        ctx1 {.inject.} = ZenContext.init(id = "ctx1", blocking_recv = true)
        ctx2 {.inject.} = ZenContext.init(id = "ctx2", blocking_recv = true)

      ctx2.subscribe(ctx1)
      Zen.thread_ctx = ctx1
      ctx1.boop(blocking = false)

      body

  template remote(body) =
    block remote:
      debug "remote run"
      const recv_duration = init_duration(milliseconds = 10)
      var
        ctx1 {.inject.} = ZenContext.init(
          id = "ctx1",
          listen_address = "127.0.0.1",
          min_recv_duration = recv_duration,
          blocking_recv = true,
        )

        ctx2 {.inject.} = ZenContext.init(
          id = "ctx2", min_recv_duration = recv_duration, blocking_recv = true
        )

      ctx2.subscribe "127.0.0.1",
        callback = proc() =
          ctx1.boop(blocking = false)

      Zen.thread_ctx = ctx1
      ctx1.boop(blocking = false)

      body

      ctx1.close
      ctx2.close

  template local_and_remote(body) =
    local(body)
    remote(body)

  test "sets":
    type TestFlags = enum
      Flag1
      Flag2
      Flag3
      Flag4

    var s = ~{Flag1, Flag2}

    check:
      Flag2 in s
      Flag2 in s
      Flag3 notin s
      Flag4 notin s
      {Flag1} in s
      {Flag1, Flag2} in s
      {Flag1, Flag2, Flag3} notin s

    var added {.threadvar.}: set[TestFlags]
    var removed {.threadvar.}: set[TestFlags]

    let zid = s.track proc(changes, zid: auto) {.gcsafe.} =
      added = {}
      removed = {}
      for c in changes:
        if Added in c.changes:
          added.incl(c.item)
        elif Removed in c.changes:
          removed.incl(c.item)

    s += Flag3
    check:
      added == {Flag3}
      removed == {}
      s ~== {Flag1, Flag2, Flag3}

    s -= {Flag1, Flag2}
    check:
      added == {}
      removed == {Flag1, Flag2}
      s ~== {Flag3}

    s.value = {Flag4, Flag1}
    check:
      added == {Flag1, Flag4}
      removed == {Flag3}

    var also_added: set[TestFlags]
    var also_removed: set[TestFlags]
    s.track proc(changes, zid: auto) {.gcsafe.} =
      also_added = {}
      also_removed = {}
      for c in changes:
        if Added in c.changes:
          also_added.incl(c.item)
        elif Removed in c.changes:
          also_removed.incl(c.item)

    s.untrack(zid)
    s ~= {Flag2, Flag3}
    check:
      added == {}
      removed == {}
      s ~== {Flag2, Flag3}
      also_added == {Flag2, Flag3}
      also_removed == {Flag1, Flag4}
    s.clear()
    check also_removed == {Flag2, Flag3}

  test "seqs":
    var
      s = ~seq[string]
      added_items {.threadvar.}: seq[string]
      removed_items {.threadvar.}: seq[string]

    var id = s.track proc(changes: auto) {.gcsafe.} =
      added_items.add changes.filter_it(Added in it.changes).map_it it.item
      removed_items.add changes.filter_it(Removed in it.changes).map_it it.item
    s.add "hello"
    s.add "world"

    check added_items == @["hello", "world"]
    s -= "world"
    check removed_items == @["world"]
    removed_items = @[]
    s.clear()
    check removed_items == @["hello"]
    s.untrack(id)

    id = s.count_changes
    1.changes:
      s += "hello"
    check s.len == 1
    1.changes:
      s.del(0)
    check s.len == 0

  test "set literal":
    type TestFlags = enum
      Flag1
      Flag2
      Flag3

    var a = ~{Flag1, Flag3}

  test "table literals":
    var a = ~Table[int, ZenSeq[string]]
    a.track proc(changes, _: auto) {.gcsafe.} =
      discard
    a[1] = ~(@["nim"])
    a[5] = ~(@["vin", "rw"])
    a.clear

  test "touch table":
    var a = ZenTable[string, string].init
    let zid = a.count_changes

    1.changes:
      a["hello"] = "world"
    0.changes:
      a["hello"] = "world"
    1.changes:
      a.touch("hello", "world")
    a.untrack_all

  test "primitive_table":
    var a = ~Table[int, int]
    a[1] = 2

  test "nested":
    var a = ZenTable[int, ZenSeq[int]].init
    a[1] = ~(@[1, 2])
    a[1] += 3

  test "nested_2":
    var a = ~{1: ~(@[1])}.to_table
    a[1] = ~(@[1, 2])
    a[1] += 3

  test "nested_changes":
    let flags = {TrackChildren, SyncLocal, SyncRemote}
    type Flags = enum
      Flag1
      Flag2

    let buffers =
      ~(
        {1: ~({1: ~(@[~{Flag1}, ~{Flag2}], flags = flags)}.to_table, flags = flags)}.to_table,
        flags = flags,
      )
    var id = buffers.count_changes

    # we're watching the top level object. Any child change will
    # come through as a single Modified change on the top level child,
    # regardless of how deep it is or how much actually changed

    1.changes:
      buffers[1][1][0] += Flag2
    0.changes:
      buffers[1][1][0] += Flag1
      # already there. No change
    1.changes:
      buffers[1][1][0] -= {Flag1, Flag2}
    1.changes:
      buffers[1][1] += ~{Flag1, Flag2}
    1.changes:
      buffers[1][1] = ~(@[~{Flag1}], flags = flags)

    # unlink
    buffers[1][1][0].clear
    let child = buffers[1][1][0]
    buffers[1][1].del 0
    0.changes:
      child += Flag1
    buffers[1][1] += child
    1.changes:
      child += Flag2

    2.changes:
      buffers[1] = nil
      # Added and Removed changes
    buffers.untrack(id)

    buffers[1] =
      ~({1: ~(@[~({Flag1}, flags = flags)], flags = flags)}.to_table, flags = flags)
    id = buffers[1][1][0].count_changes
    1.changes:
      buffers[1][1][0] += {Flag1, Flag2}
    0.changes:
      buffers[1][1][0] += {Flag1, Flag2}
    2.changes:
      buffers[1][1][0] -= {Flag1, Flag2}
    1.changes:
      buffers[1][1][0].touch Flag1
    0.changes:
      buffers[1][1][0] += Flag1
    1.changes:
      buffers[1][1][0].touch Flag1
    2.changes:
      buffers[1][1][0].touch {Flag1, Flag2}
    2.changes:
      buffers[1][1][0].touch {Flag1, Flag2}

    buffers[1][1][0].untrack(id)

    var changed = false
    id = buffers.track proc(changes, _: auto) {.gcsafe.} =
      if not changed:
        changed = true
        check changes.len == 2
        check changes[0].changes == {Removed, Modified}
        check not changes[0].item.value.is_nil
        check changes[1].changes == {Added, Modified}
        check changes[1].item.value.is_nil
    buffers[1] = nil
    check changed
    buffers.untrack(id)

    buffers.count_changes
    1.changes:
      buffers.del(1)
    check 1 notin buffers

  test "comparable aliases":
    var a = ZenTable[int, string].init(id = "1")
    var b = Zen[Table[int, string], Pair[int, string]].init(id = "1")
    var c = ZenTable[string, int].init(id = "2")
    check b is ZenTable[int, string]
    check a == b
    when compiles(a == c):
      check false, &"{a.type} and {b.type} shouldn't be comparable"

  test "init from type":
    type TestFlag = enum
      Flag1
      Flag2

    var a = ~seq[int]
    var b = ~set[TestFlag]
    check:
      a is Zen[seq[int], int]
      b is Zen[set[TestFlag], TestFlag]

  test "nested_triggers":
    type
      UnitFlags = enum
        Targeted
        Highlighted

      Unit = ref object of RootRef
        id: int
        parent: Unit
        units: Zen[seq[Unit], Unit]
        flags: ZenSet[UnitFlags]

    proc init(
        _: type Unit, id = 0, flags = {TrackChildren, SyncLocal, SyncRemote}
    ): Unit =
      result = Unit(id: id)
      result.units = ~(seq[Unit], flags)
      result.flags = ~(set[UnitFlags], flags)

    var a = Unit.init
    var id = a.units.count_changes
    var b = Unit.init
    1.changes:
      a.units.add b
    var c = Unit.init
    1.changes:
      b.units.add c
    a.units.untrack(id)

    var triggered_by {.threadvar.}: seq[seq[BaseChange]]
    a.units.track proc(changes: auto) {.gcsafe.} =
      triggered_by = @[]
      for change in changes:
        triggered_by.add change.triggered_by

    let d = Unit.init(id = 222)
    c.units.add d
    check triggered_by[0][0].triggered_by[0] of Change[Unit]
    check triggered_by[0][0].triggered_by_type == "Unit"
    let x = Change[Unit](triggered_by[0][0].triggered_by[0])
    check x.item.id == 222
    d.flags += Targeted
    let trigger = triggered_by[0][0].triggered_by[0].triggered_by[0]
    check trigger of Change[UnitFlags]
    let f = Change[UnitFlags](trigger)
    check Added in f.changes
    check f.item == Targeted

    # without child tracking:
    a = Unit.init(flags = {SyncLocal, SyncRemote})
    id = a.units.count_changes
    b = Unit.init
    1.changes:
      a.units.add b
    c = Unit.init
    0.changes:
      b.units.add c
    a.units.untrack(id)

  test "primitives":
    let a = ZenValue[int].init
    a.assert_changes {
      Removed: 0,
      Added: 5,
      Removed: 5,
      Added: 10,
      Touched: 10,
      Removed: 10,
      Touched: 11,
      Removed: 11,
      Added: 12
    }:
      a ~= 5
      a ~= 10
      a.touch 10
      a.touch 11
      a.touch 12

    let b = ~4
    b.assert_changes {Removed: 4, Added: 11}:
      b ~= 11

    let c = ~"enu"
    c.assert_changes {Removed: "enu", Added: "ENU"}:
      c ~= "ENU"

  test "refs":
    type ARef = ref object of RootObj
      id: int

    let (r1, r2, r3) = (ARef(id: 1), ARef(id: 2), ARef(id: 3))

    let a = ~r1
    a.assert_changes {Removed: r1, Added: r2, Removed: r2, Added: r3}:
      a ~= r2
      a ~= r3

  test "pausing":
    var s = ZenValue[string].init
    let zid = s.count_changes
    2.changes:
      s ~= "one"
    s.pause zid:
      0.changes:
        s ~= "two"
    2.changes:
      s ~= "three"
    let zids = @[zid, 1234]
    s.pause zids:
      0.changes:
        s ~= "four"
    2.changes:
      s ~= "five"
    s.pause zid, 1234:
      0.changes:
        s ~= "six"
    2.changes:
      s ~= "seven"
    s.pause:
      0.changes:
        s ~= "eight"
    2.changes:
      s ~= "nine"

    var calls = 0
    s.changes:
      calls += 1
      s ~= "cal"

    s ~= "vin"
    check calls == 2

  test "closed":
    var s = ~""
    var changed = false

    s.track proc(changes: auto) {.gcsafe.} =
      changed = true
      check changes[0].changes == {Closed}
    s.untrack_all
    check changed == true

    changed = false
    let zid = s.track proc(changes: auto) {.gcsafe.} =
      changed = true
      check changes[0].changes == {Closed}
    Zen.thread_ctx.untrack(zid)
    check changed == true

  test "init_props":
    type Model = ref object
      list: ZenSeq[int]
      field: string
      zen_field: ZenValue[string]

    proc init(_: type Model): Model =
      result = Model()
      result.init_zen_fields

    let m = Model.init
    m.zen_field ~= "test"
    check m.zen_field ~== "test"

  test "sync":
    type
      Thing = ref object of RootObj
        id: string

      Tree = ref object
        zen: ZenValue[string]
        things: ZenSeq[Thing]
        values: ZenSeq[ZenValue[string]]

      Container = ref object
        thing1: ZenValue[Thing]
        thing2: ZenValue[Thing]

    Zen.register(Thing, false)

    local_and_remote:
      var s1 = ZenValue[string].init(ctx = ctx1)
      ctx2.boop
      var s2 = ZenValue[string](ctx2[s1])
      check s2.ctx != nil

      s1 ~= "sync me"
      ctx2.boop

      check ~s2 == ~s1

      s1 &= " and me"
      ctx2.boop

      check ~s2 == ~s1 and ~s2 == "sync me and me"

      var msg = "hello world"
      var another_msg = "another"
      var src = Tree().init_zen_fields(ctx = ctx1)
      ctx2.boop
      var dest = Tree.init_from(src, ctx = ctx2)

      src.zen ~= "hello world"
      ctx2.boop
      check ~src.zen == "hello world"
      check ~dest.zen == "hello world"

      let thing = Thing(id: "Vin")
      src.things += thing
      ctx2.boop
      check dest.things.len == 1
      check dest.things[0] != nil
      check dest.things[0].id == "Vin"

      src.things -= thing
      check src.things.len == 0

      ctx2.boop

      check dest.things.len == 0

      var container = Container().init_zen_fields(ctx = ctx1)

      var t = Thing(id: "Scott")
      ctx2.boop
      var remote_container = Container.init_from(container, ctx = ctx2)
      container.thing1 ~= t
      container.thing2 ~= t

      check container.thing1 ~==~ container.thing2

      sleep(100)
      ctx2.boop

      check remote_container.thing1.value.id == container.thing1.value.id
      check remote_container.thing1.value == remote_container.thing2.value
      var s3 = ZenValue[string].init(ctx = ctx1)
      src.values += s3
      s3.value = "hi"
      ctx2.boop
      check dest.values[^1].value == "hi"

      var ctx3 = ZenContext.init(id = "ctx3")
      Zen.thread_ctx = ctx3
      ctx3.subscribe(ctx2, bidirectional = false)
      Zen.thread_ctx = ctx1
      check ctx3.len == ctx1.len
      src.values += ~("", ctx = ctx1)
      check ctx1.len != ctx2.len and ctx1.len != ctx3.len
      ctx2.boop
      check ctx1.len == ctx2.len and ctx1.len != ctx3.len
      Zen.thread_ctx = ctx3
      ctx3.boop
      Zen.thread_ctx = ctx1
      check ctx1.len == ctx2.len and ctx1.len == ctx3.len

  test "delete":
    local_and_remote:
      var a = ~("", ctx = ctx1)
      check ctx1.len == 1
      ctx2.boop
      check ctx1.len == 1
      check ctx2.len == 1

      a.destroy
      check ctx1.len == 0
      ctx2.boop
      check ctx1.len == 0
      check ctx2.len == 0

  test "sync nested":
    type Unit = ref object of RootObj
      units: ZenSeq[Unit]
      code: ZenValue[string]
      id: int

    Zen.register(Unit, false)
    local_and_remote:
      var u1 = Unit(id: 1)
      var u2 = Unit(id: 2)
      u1.init_zen_fields
      u2.init_zen_fields
      ctx2.boop

      var ru1 = Unit.init_from(u1, ctx = ctx2)

      u1.units += u2
      ctx2.boop
      check ru1.units[0].code.ctx == ctx2

  test "zentable of tables":
    type Shared = ref object of RootObj
      id: string
      edits: ZenTable[int, Table[string, string]]

    Zen.register(Shared, false)

    local_and_remote:
      var container: ZenValue[Shared]
      container.init

      var shared = Shared(id: "1")
      shared.init_zen_fields

      container.value = shared
      container.value.edits[1] = {"1": "one", "2": "two"}.to_table
      ctx2.boop

      var dest = type(container)(ctx2[container])
      check 1 in dest.value.edits
      check dest.value.edits[1].len == 2
      check dest.value.edits[1]["2"] == "two"

      container.value.edits +=
        {2: {"3": "three"}.to_table, 3: {"4": "four"}.to_table}.to_table

      ctx2.boop
      check dest.value.edits.len == 3
      check dest.value.edits[3]["4"] == "four"

  test "zentable of zentables":
    type Block = ref object of RootObj
      id: string
      chunks: ZenTable[int, ZenTable[string, string]]

    local_and_remote:
      var container: ZenValue[Block]
      container.init

      var shared = Block(id: "2")
      shared.init_zen_fields

      ctx2.boop
      var shared2 = Block.init_from(shared, ctx = ctx2)

      shared.chunks[1] = ZenTable[string, string].init
      shared.chunks[1]["hello"] = "world"
      Zen.thread_ctx = ctx2
      ctx2.boop

      check addr(shared.chunks[]) != addr(shared2.chunks[])
      check shared2.chunks[1]["hello"] == "world"

      shared2.chunks[1]["hello"] = "goodbye"
      Zen.thread_ctx = ctx1
      ctx1.boop

      check shared.chunks[1]["hello"] == "goodbye"

  test "free refs":
    type RefType = ref object of RootObj
      id: string

    Zen.register(RefType, false)

    local_and_remote:
      var src = ZenSeq[RefType].init

      var obj = RefType(id: "1")

      src += obj

      ctx2.boop
      var dest = ZenSeq[RefType](ctx2[src])

      private_access ZenContext
      private_access CountedRef

      check obj.ref_id in ctx1.ref_pool
      check obj.ref_id in ctx2.ref_pool
      check obj.ref_id notin ctx2.freeable_refs

      let orig_dest_obj = RefType(ctx2.ref_pool[obj.ref_id].obj)
      src -= obj
      ctx2.boop
      check obj.ref_id in ctx2.ref_pool
      check obj.ref_id in ctx2.freeable_refs
      check ctx2.ref_pool[obj.ref_id].references.card == 0

      src += obj
      ctx2.boop
      check obj.ref_id in ctx2.ref_pool
      check obj.ref_id in ctx2.freeable_refs
      check ctx2.ref_pool[obj.ref_id].references.card == 1
      check dest[0] == orig_dest_obj
      src -= obj
      ctx2.boop

      # after a timeout the unreferenced object will be removed
      # from the dest ref_pool and freeable_refs, and if we add
      # it back to src a new object will be created in dest
      ctx2.freeable_refs[obj.ref_id] = MonoTime.low
      ctx2.boop(blocking = false)
      check obj.ref_id notin ctx2.ref_pool
      check obj.ref_id notin ctx2.freeable_refs
      check dest.len == 0

      src += obj
      ctx2.boop
      check dest[0].id == orig_dest_obj.id
      check dest[0] != orig_dest_obj

  test "sync set":
    type Flags = enum
      One
      Two
      Three

    local_and_remote:
      let msg = "hello world"
      var src = ZenSet[Flags].init
      ctx2.boop
      var dest = ZenSet[Flags](ctx2[src])
      src += One
      ctx2.boop
      check dest.value == {One}
      dest += Two
      ctx1.boop
      check src.value == {One, Two}

  test "seq of tuples":
    local_and_remote:
      let val = ("hello", 1)
      let z = ZenSeq[val.type].init
      ctx2.boop
      z += val
      ctx2.boop
      z += val
      ctx2.boop
      let z2 = ctx2[z]
      check z2.len == 2

  test "pointer to ref":
    type RefType = ref object of RootObj
      id: string

    local_and_remote:
      let a = RefType(id: "a")
      var src = ZenValue[ptr RefType].init

      ctx2.boop
      var dest = ZenValue[ptr RefType](ctx2[src])

      src.value = unsafe_addr(a)
      ctx2.boop

      check dest.value[].id == "a"

  test "object with registered ref":
    type
      RefType2 = ref object of RootObj
        id: string

      RefType3 = ref object of RefType2

      Query = object
        target: RefType2
        other: string

    Zen.register(RefType3, false)

    local_and_remote:
      let a = Query(target: RefType3(id: "b"), other: "hello")
      var src = ZenValue[Query].init

      ctx2.boop
      var dest = ZenValue[Query](ctx2[src])

      src.value = a
      ctx2.boop

      check:
        src.value.target.id == dest.value.target.id
        src.value.other == dest.value.other
        src.value.target != dest.value.target

  test "triggered by sync":
    type
      UnitFlags = enum
        Targeted
        Highlighted

      SyncUnit = ref object of RootRef
        id: int
        parent: SyncUnit
        units: ZenSeq[SyncUnit]

      State = ref object
        units: ZenSeq[SyncUnit]
        active: SyncUnit

    Zen.register(SyncUnit, false)

    local_and_remote:
      let flags = {TrackChildren, SyncLocal, SyncRemote}
      var src = State().init_zen_fields(flags = flags)

      ctx2.boop
      var dest = State.init_from(src, ctx = ctx2)
      var src_change_id = 0
      var dest_change_id = 0

      src.units.changes:
        var change = change
        while change.triggered_by.len > 0:
          change = Change[SyncUnit](change.triggered_by[0])
        src_change_id = change.item.id

      dest.units.changes:
        var change = change
        while change.triggered_by.len > 0:
          change = Change[SyncUnit](change.triggered_by[0])
        dest_change_id = change.item.id

      let base = SyncUnit(id: 1).init_zen_fields(flags = flags)
      src.units.add base
      ctx2.boop

      let child = SyncUnit(id: 3).init_zen_fields(flags = flags)
      ctx2.boop
      src_change_id = 0
      dest_change_id = 0
      base.units.add child

      ctx2.boop
      check src_change_id == 3
      check dest_change_id == 3

      Zen.thread_ctx = ctx2
      let grandchild =
        SyncUnit(id: 4).init_zen_fields(ctx = ctx2, flags = flags)

      dest.units[0].units.add grandchild

      ctx1.boop
      check src_change_id == 4
      check dest_change_id == 4

  test "Vector3 array type should create ZenValue not ZenSeq":
    var vec = Vector3([1.0, 2.0, 3.0])
    var zen_vec = ~vec
    
    # Verify this is a ZenValue[Vector3], not a ZenSeq[float]
    check zen_vec is ZenValue[Vector3]
    check zen_vec.value == vec
    
    # Test that it can sync properly
    var ctx1 = init_test_ctx("ctx1") 
    var ctx2 = init_test_ctx("ctx2")
    ctx2.subscribe(ctx1)
    
    var v1 = Zen.init(vec, ctx = ctx1, id = "vector")
    ctx1.boop
    
    var v2 = ZenValue[Vector3](ctx2["vector"])
    check v1.value == v2.value
    
    # Test mutation
    v1.value = Vector3([4.0, 5.0, 6.0])
    ctx1.boop
    check v2.value == Vector3([4.0, 5.0, 6.0])

when is_main_module:
  Zen.bootstrap
  run()
