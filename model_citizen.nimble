version = "0.19.9"
author = "Scott Wadden"
description = "Nothing for now"
license = "MIT"
srcDir = "src" # atlas doesn't like src_dir

requires(
  "nim >= 2.2.0", "https://github.com/treeform/pretty", "threading",
  "chronicles", "flatty", "netty", "supersnappy",
  "https://github.com/getenu/nanoid.nim", "metrics#51f1227",
)
