#!/bin/bash
set -e

# Download a tarball from npm containing the latest copy of speedscope
npm pack speedscope

# Next, unpack the tarball
tar -xvvf speedscope-*.tgz

# Replace the existing sources with the sources contained by the tarball
rm -rf speedscope
mkdir speedscope
mv package/LICENSE package/dist/release/*.{html,css,js,png,txt} speedscope

# Clean up
rm -rf package speedscope-*.tgz
