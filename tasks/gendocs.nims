#!/usr/bin/env nim
# Ed Documentation Generator
# Run with: nim e tasks/gendocs.nims

import std/[os, strutils]

const
  srcDir = "src"
  outDir = "docs/html"
  cssFile = "docs/nimdoc.css"
  enuSiteDir = "../enu-site/ed"

proc main() =
  echo "Generating Ed documentation..."

  # Create output directory
  if not dirExists(outDir):
    mkDir(outDir)

  # Generate documentation
  let cmd = "nim doc --project --index:on --outdir:" & outDir &
            " --css:" & cssFile &
            " " & srcDir / "ed.nim"

  echo "Running: ", cmd
  let exitCode = execShellCmd(cmd)

  if exitCode != 0:
    echo "Documentation generation failed with exit code: ", exitCode
    quit(1)

  echo "Documentation generated in ", outDir

  # Copy to enu-site if it exists
  if dirExists(enuSiteDir.parentDir):
    echo "Copying to ", enuSiteDir
    if not dirExists(enuSiteDir):
      mkDir(enuSiteDir)

    for file in walkDir(outDir):
      let dest = enuSiteDir / file.path.extractFilename
      echo "  ", file.path, " -> ", dest
      copyFile(file.path, dest)

    echo "Documentation deployed to enu-site"
  else:
    echo "Note: enu-site directory not found, skipping deployment"

  echo "Done!"

main()
