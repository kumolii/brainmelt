#!/bin/bash
rm -rf ./build
rm -rf ./dist
mkdir -p ./build
mkdir -p ./dist
trap 'rm -rf "$bundle_dir"' EXIT
cp -r *.lua palette.bin ./tests ./build
luvi --output ./dist/brainmelt ./build/ /usr/bin/luvit
chmod +x ./dist/brainmelt
./test.sh
echo "Note: If anything in binary failed, but nothing in source failed, there was likely a build error!!!"
du -hs ./dist/brainmelt
sudo cp ./dist/brainmelt /usr/bin/