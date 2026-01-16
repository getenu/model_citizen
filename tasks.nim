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

  if dirExists(out_dir):
    rmDir(out_dir)
  mkDir(out_dir)

  let cmd = "nim doc --project --index:off " &
            "-d:chronicles_enabled=off " &
            "--outdir:" & out_dir & " " & src_dir / "ed.nim"

  echo "Running: ", cmd
  exec cmd

  # Copy custom CSS to output directory (and subdirs)
  cpFile(css_file, out_dir / "nimdoc.out.css")
  for dir in walkDirRec(out_dir, {pcDir}):
    cpFile(css_file, dir / "nimdoc.out.css")

  # Rename ed.html to index.html for proper URL handling
  if fileExists(out_dir / "ed.html"):
    mvFile(out_dir / "ed.html", out_dir / "index.html")

  echo "Documentation generated in ", out_dir

  if dirExists(enu_site_dir.parentDir):
    echo "Copying to ", enu_site_dir

    # Remove old docs
    if dirExists(enu_site_dir):
      rmDir(enu_site_dir)
    mkDir(enu_site_dir)

    # Copy all files recursively
    for item in walkDirRec(out_dir, {pcFile, pcDir}):
      let rel_path = item.relativePath(out_dir)
      let dest = enu_site_dir / rel_path
      if item.dirExists:
        mkDir(dest)
      else:
        let dest_dir = dest.parentDir
        if not dirExists(dest_dir):
          mkDir(dest_dir)
        cpFile(item, dest)
        echo "  ", item, " -> ", dest

    echo "Documentation deployed to enu-site"
  else:
    echo "Note: enu-site directory not found, skipping deployment"

  echo "Done!"
