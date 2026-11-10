#!/bin/bash
# Double-click to start the Print Station planner server on this Mac.
# Leave this window open: closing it stops the planner for every screen in the office.
cd "$(dirname "$0")"
echo "Starting the Print Station planner server..."
echo "Keep this window open. Close it (or press Ctrl+C) to stop the planner."
echo
exec /usr/bin/ruby server.rb
