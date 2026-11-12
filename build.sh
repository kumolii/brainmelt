#!/bin/bash
rm -rf ./build
rm -rf ./dist
mkdir -p ./build
mkdir -p ./dist
trap 'rm -rf "$bundle_dir"' EXIT
cp -r *.lua palette.bin ./tests ./build
rm ./build/mainSmall.lua ./build/generatePalette.lua
luvi --output ./dist/brainmelt ./build/ /usr/bin/luvit
mkdir ./build/small/
cp *.lua ./build/small
rm ./build/small/main.lua ./build/small/audio.lua ./build/small/display.lua ./build/small/generatePalette.lua
mv ./build/small/mainSmall.lua ./build/small/main.lua
luvi --output ./dist/brainmeltSmall ./build/small/ /usr/bin/luvit
chmod +x ./dist/*
./test.sh
echo "Note: If anything in binary failed, but nothing in source failed, there was likely a build error!!!"
du -hs ./dist/brainmelt
sudo cp ./dist/brainmelt /usr/bin/
du -hs ./dist/brainmeltSmall #working on making this actually small