import model_citizen/[core, types {.all.}]

proc init*(
    _: type Change, T: type, changes: set[ChangeKind], field_name = ""
): Change[T] =
  Change[T](changes: changes, type_name: $Change[T], field_name: field_name)

proc init*[T](
    _: type Change, item: T, changes: set[ChangeKind], field_name = ""
): Change[T] =
  result = Change[T](
    item: item, changes: changes, type_name: $Change[T], field_name: field_name
  )

proc init*(
    _: type OperationContext,
    source: HashSet[string] = initHashSet[string](),
    ctx: ZenContext = nil,
): OperationContext =
  result = OperationContext()
  result.source = source
  if ?ctx:
    result.source.incl ctx.id
  when defined(zen_trace):
    result.trace = get_stack_trace()

template setup_op_ctx*(self: ZenContext) =
  let op_ctx =
    if ?op_ctx:
      op_ctx
    else:
      OperationContext.init(source = [self.id].toHashSet)

template privileged*() =
  private_access ZenContext
  private_access ZenBase
  private_access ZenObject
