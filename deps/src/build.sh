#!/bin/bash

# User docker to build pa_ringbuffer library for all supported platforms.

set -e

make clean

# NOTE: the darwin build ends up actually being x86_64-apple-darwin14. It gets
# mapped within the docker machine
for platform in \
    	arm-linux-gnueabihf \
    	powerpc64le-linux-gnu \
    	x86_64-apple-darwin \
    	x86_64-w64-mingw32 \
    	i686-w64-mingw32; do
    echo "================================"
    echo "building for $platform..."
    docker run --rm -v \
        $(pwd)/../..:/workdir \
        -w /workdir/deps/src \
        -e CROSS_TRIPLE=$platform multiarch/crossbuild \
        ./dockerbuild_cb.sh
    echo "================================"
    echo ""
done

# x86_64-linux-gnu.so \
#     	i686-linux-gnu.so \
