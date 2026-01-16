import std/[os, strutils]

const
  srcDir = "src"
  outDir = "docs/html"
  cssFile = "docs/nimdoc.css"
  enuSiteDir = "../enu-site/ed"

task test, "Run all tests":
  exec "nim c -r tests/tests.nim"
  exec "nim c -r tests/threading_tests.nim"

task docs, "Generate Ed documentation":
  echo "Generating Ed documentation..."

  if not dirExists(outDir):
    mkDir(outDir)

  let cmd = "nim doc --project --index:on --outdir:" & outDir &
            " --css:" & cssFile &
            " " & srcDir / "ed.nim"

  echo "Running: ", cmd
  exec cmd

  echo "Documentation generated in ", outDir

  if dirExists(enuSiteDir.parentDir):
    echo "Copying to ", enuSiteDir
    if not dirExists(enuSiteDir):
      mkDir(enuSiteDir)

    for file in walkDir(outDir):
      let dest = enuSiteDir / file.path.extractFilename
      echo "  ", file.path, " -> ", dest
      cpFile(file.path, dest)

    echo "Documentation deployed to enu-site"
  else:
    echo "Note: enu-site directory not found, skipping deployment"

  echo "Done!"
