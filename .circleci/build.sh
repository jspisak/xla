#!/bin/bash

source ./env

set -ex

SCCACHE="$(which sccache)"
if [ -z "${SCCACHE}" ]; then
  echo "Unable to find sccache..."
  exit 1
fi

if which sccache > /dev/null; then
  # Save sccache logs to file
  sccache --stop-server || true
  rm ~/sccache_error.log || true
  SCCACHE_ERROR_LOG=~/sccache_error.log RUST_LOG=sccache::server=error sccache --start-server

  # Report sccache stats for easier debugging
  sccache --zero-stats
fi

# Try rebasing on top of pytorch/xla master first.
# This allows us to pickup the latest fix for PT-XLA breakage.
# Also it might improve build time as we have warm cache.
git config --global user.email "circleci.ossci@gmail.com"
git config --global user.name "CircleCI"
git rebase origin/master

PYTORCH_DIR=/tmp/pytorch
XLA_DIR="$PYTORCH_DIR/xla"
git clone --recursive --quiet https://github.com/pytorch/pytorch.git "$PYTORCH_DIR"
cp -r "$PWD" "$XLA_DIR"

cd $PYTORCH_DIR

# Install ninja to speedup the build
pip install ninja

# Install the Lark parser required for the XLA->ATEN Type code generation.
pip install lark-parser

# Install hypothesis, required for running some PyTorch test suites
pip install hypothesis

# Install Pytorch without MKLDNN
xla/scripts/apply_patches.sh
python setup.py build develop
sccache --show-stats

# Bazel doesn't work with sccache gcc. https://github.com/bazelbuild/bazel/issues/3642
sudo add-apt-repository "deb http://apt.llvm.org/xenial/ llvm-toolchain-xenial-8 main"
wget -O - https://apt.llvm.org/llvm-snapshot.gpg.key|sudo apt-key add -
sudo apt-get -qq update
sudo apt-get -qq install clang-8 clang++-8

# XLA build requires Bazel
# We use bazelisk to avoid updating Bazel version manually.
sudo add-apt-repository ppa:longsleep/golang-backports
sudo apt-get update
sudo apt-get -qq install golang-go
go get github.com/bazelbuild/bazelisk
export PATH=$PATH:$(go env GOPATH)/bin
sudo ln -s `which bazelisk` /usr/bin/bazel

# Install bazels3cache for cloud cache
sudo apt-get -qq install npm
npm config set strict-ssl false
curl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -
sudo apt-get install -qq nodejs
sudo npm install -g bazels3cache
BAZELS3CACHE="$(which bazels3cache)"
if [ -z "${BAZELS3CACHE}" ]; then
  echo "Unable to find bazels3cache..."
  exit 1
fi

echo "Installing torchvision at branch master"
rm -rf vision
# TODO: This git clone is bad, it means pushes to torchvision can break
# PyTorch CI
git clone https://github.com/pytorch/vision --quiet
pushd vision
# python setup.py install with a tqdm dependency is broken in the
# Travis Python nightly (but not in latest Python nightlies, so
# this should be a transient requirement...)
# See https://github.com/pytorch/pytorch/issues/7525
#time python setup.py install
pip install -q --user .
popd

bazels3cache --bucket=${XLA_CLANG_CACHE_S3_BUCKET_NAME} --maxEntrySizeBytes=0 --logging.level=verbose

# install XLA
pushd "$XLA_DIR"
# Use cloud cache to build when available.
sed -i '/bazel build/ a --remote_http_cache=http://localhost:7777 \\' build_torch_xla_libs.sh

source ./xla_env
python setup.py install
popd
