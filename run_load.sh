#!/bin/bash
docker run --rm -v $(pwd):/app -w /app --network host elixir:1.15 bash -c "mix local.hex --force && mix local.rebar --force && mix deps.get && mix compile && mix run run_load.exs"
