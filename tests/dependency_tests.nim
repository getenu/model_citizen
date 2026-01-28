import std/[unittest, tables, sequtils, sugar]
import ed
import ed/[types {.all.}]
import ed/components/subscriptions
import ed/zens/operations

proc run*() =
  test "get_dependencies seq":
    var seqOfEds = EdSeq[EdValue[int]].init
    var v1 = EdValue[int].init
    var v2 = EdValue[int].init
    seqOfEds.add v1
    seqOfEds.add v2

    let deps = seqOfEds.get_dependencies()
    check deps.len == 2
    check v1.id in deps
    check v2.id in deps

  test "get_dependencies table":
    var tableOfEds = EdTable[string, EdValue[int]].init
    var v1 = EdValue[int].init
    var v2 = EdValue[int].init
    tableOfEds["v1"] = v1
    tableOfEds["v2"] = v2

    let tableDeps = tableOfEds.get_dependencies()
    check tableDeps.len == 2
    check v1.id in tableDeps
    check v2.id in tableDeps

  #  test "get_dependencies nested":
  #    var v1 = EdValue[int].init
  #    var nested = ed(v1)
  #    let nestedDeps = nested.get_dependencies()
  #    check nestedDeps.len == 1
  #    check v1.id in nestedDeps
  test "get_dependency_order":
    var ctx = EdContext.init(id = "dep_test_ctx")

    # Simple chain: A -> B (A depends on B)
    var a = EdSeq[EdValue[int]].init(ctx = ctx)
    var b = EdValue[int].init(ctx = ctx)
    a.add b

    var order = ctx.get_dependency_order()
    var relevant = order.filterIt(it == a.id or it == b.id)
    check relevant == @[a.id, b.id]

    # Longer chain: GP -> P -> C
    var gp = EdSeq[EdSeq[EdValue[int]]].init(ctx = ctx)
    var p = EdSeq[EdValue[int]].init(ctx = ctx)
    var c = EdValue[int].init(ctx = ctx)

    gp.add p
    p.add c

    order = ctx.get_dependency_order()
    relevant = order.filterIt(it == gp.id or it == p.id or it == c.id)
    check relevant == @[gp.id, p.id, c.id]

    # Shared dependency (Diamond/DAG): A -> [B, C], B -> D, C -> D
    var nodeA = EdSeq[EdSeq[EdValue[int]]].init(ctx = ctx)
    var nodeB = EdSeq[EdValue[int]].init(ctx = ctx)
    var nodeC = EdSeq[EdValue[int]].init(ctx = ctx)
    var nodeD = EdValue[int].init(ctx = ctx)

    nodeA.add nodeB
    nodeA.add nodeC
    nodeB.add nodeD
    nodeC.add nodeD

    order = ctx.get_dependency_order()
    relevant = order.filterIt(
      it == nodeA.id or it == nodeB.id or it == nodeC.id or it == nodeD.id
    )

    # A must be first
    check relevant[0] == nodeA.id
    # D must be last
    check relevant[^1] == nodeD.id
    # B and C in between
    check relevant.contains(nodeB.id)
    check relevant.contains(nodeC.id)
