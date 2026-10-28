#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test/fixtures
ffmpeg -y -hide_banner -loglevel error -f lavfi -i "flite=text='Remember to send Sam the project proposal tomorrow morning.':voice=slt" -ar 16000 -ac 1 -c:a pcm_s16le test/fixtures/idea.wav
ffmpeg -y -hide_banner -loglevel error -i test/fixtures/idea.wav -c:a aac -b:a 64k test/fixtures/idea.m4a
ffmpeg -y -hide_banner -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 2 -c:a pcm_s16le test/fixtures/silence.wav
ffmpeg -y -hide_banner -loglevel error -i test/fixtures/idea.wav -af 'adelay=500|500,apad=pad_dur=3' -ar 16000 test/fixtures/idea-with-pause.wav
