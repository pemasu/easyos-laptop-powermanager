#!/bin/sh
# Turns vpower-engine.sh into engine.h (needs only od + awk)
{
  echo "static const unsigned char engine_sh[] = {"
  od -An -v -tu1 vpower-engine.sh | awk '{for(i=1;i<=NF;i++) printf "%s,", $i; print ""}'
  echo "};"
  echo "static const unsigned int engine_sh_len = sizeof(engine_sh);"
} > engine.h
