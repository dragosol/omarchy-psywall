#!/bin/sh
# Rebuilds preview.png, the marketplace card, from docs/window.png. Run from the repo root.
# The generator is the house-style card builder from the omarchy-plugin-publish skill.
exec python3 tools/make_preview.py --shot docs/window.png --icon tools/icon.svg \
  --name Psywall --name2 'Light Show' --accent '#d946ef' \
  --tagline 'Your wallpaper and|your Hue lights,|moving to the music.' \
  --features 'Hue lights · 50 fps|beat · glow · place' --shot-width 660 --out preview.png
