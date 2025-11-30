#!/bin/bash
MIX_ENV=dev elixir \
  --sname mosaic_app@mosaic \
  --cookie supersecretcookie \
  --erl "-pa /app/_build/dev/lib -kernel allow_SU_members true" \
  -e "Application.ensure_all_started(:mosaic); Application.ensure_all_started(:nx);
Application.ensure_all_started(:exla); Process.sleep(:infinity)"
