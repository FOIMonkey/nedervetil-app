#!/bin/sh

rm -f tmp/pids/server.pid
exec bin/dev -b 0.0.0.0
