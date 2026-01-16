import std/[os, strutils]

const
  src_dir = "src"
  out_dir = "docs/html"
  css_file = "docs/nimdoc.css"
  enu_site_dir = "../enu-site/ed"

task test, "Run all tests":
  exec "nim c -r tests/tests.nim"
  exec "nim c -r tests/threading_tests.nim"

task docs, "Generate Ed documentation":
  echo "Generating Ed documentation..."

  if not dirExists(out_dir):
    mkDir(out_dir)

  let cmd = "nim doc --index:off " &
            "-d:chronicles_enabled=off " &
            "--outdir:" & out_dir & " " & src_dir / "ed.nim"

  echo "Running: ", cmd
  exec cmd

  # Copy custom CSS to output directory
  cpFile(css_file, out_dir / "nimdoc.out.css")

  echo "Documentation generated in ", out_dir

  if dirExists(enu_site_dir.parentDir):
    echo "Copying to ", enu_site_dir
    if not dirExists(enu_site_dir):
      mkDir(enu_site_dir)

    for file in walkDir(out_dir):
      let dest = enu_site_dir / file.path.extractFilename
      echo "  ", file.path, " -> ", dest
      cpFile(file.path, dest)

    echo "Documentation deployed to enu-site"
  else:
    echo "Note: enu-site directory not found, skipping deployment"

  echo "Done!"
