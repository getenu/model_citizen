# Ed

Ed is Enu's reactive data framework for Nim. It provides thread-safe, network-synchronized data containers that enable reactive programming patterns.

## Features

- **Reactive containers**: EdValue, EdSeq, EdTable, EdSet - track and react to data changes
- **Thread synchronization**: Safely share data across threads with automatic sync
- **Network synchronization**: Sync data across network connections
- **Change tracking**: Detailed callbacks for data modifications (added, removed, modified, touched)
- **Nested reactivity**: Track changes through deep object hierarchies

## Installation

```bash
nimble install model_citizen
```

## Quick Start

```nim
import ed

# Bootstrap Ed (required once per application)
Ed.bootstrap

# Create reactive values
let name = ed("Enu")
let score = EdValue[int].init

# Track changes
name.track proc(changes: auto) =
  for change in changes:
    if ADDED in change.changes:
      echo "Name changed to: ", change.item

# Modify data (triggers callbacks)
name.value = "World"
score.value = 42
```

## Reactive Collections

```nim
# Sequences
var items = EdSeq[string].init
items.add "one"
items.add "two"
items -= "one"

# Tables
var config = EdTable[string, int].init
config["timeout"] = 30
config["retries"] = 3

# Sets
var flags = EdSet[MyFlag].init
flags += Active
flags += Visible
```

## Cross-Thread Sync

```nim
var ctx1 = EdContext.init(id = "thread1")
var ctx2 = EdContext.init(id = "thread2")

ctx2.subscribe(ctx1)

# Create data in ctx1
var data = EdValue[string].init(ctx = ctx1)
data.value = "synced"

# Data automatically available in ctx2
ctx2.tick
```

## Documentation

Full documentation: https://getenu.com/ed

## Warning

Data consistency in Ed is eventual, not guaranteed. Do not use for critical data where strong consistency is required. Full consistency support is planned for future versions.

## License

MIT
