#!/bin/bash
set -e

echo "Building LLPTP..."
mkdir -p build
swiftc main.swift -o build/llptp \
    -framework CoreAudio \
    -framework AudioToolbox \
    -O \
    -whole-module-optimization

echo "Build complete: ./build/llptp"
echo ""
echo "Usage:"
echo "  ./build/llptp --list                  List input devices"
echo "  ./build/llptp --device 0              Passthrough from device 0"
echo "  ./build/llptp --device 0 --buffer 128 Custom buffer size"
echo "  ./build/llptp                         Interactive mode"
