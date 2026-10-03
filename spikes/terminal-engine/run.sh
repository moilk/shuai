#!/bin/bash
# usage: run.sh <engine> <auto: dump|bench|both> [prefix]   (from spikes/terminal-engine)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
B=dev.shuai.spike.enginespike
xcrun simctl terminate booted $B 2>/dev/null
D=$(xcrun simctl get_app_container booted $B data); rm -f $D/Documents/*
xcrun simctl launch booted $B -engine $1 -auto $2 -prefix ${3:-0} >/dev/null
for i in $(seq 1 90); do sleep 1; [ -f $D/Documents/report-$1.json ] && break; done
cat $D/Documents/report-$1.json; mkdir -p results; cp $D/Documents/* results/ 2>/dev/null
