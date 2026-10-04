set shell := ['/bin/bash', '-c']

export CONTOOL := shell('command -v podman 2>&1 || command -v docker')

_init_clone:
  [ -e chromium ] || git clone --filter=tree:0 --no-checkout https://github.com/chromium/chromium

[working-directory: 'chromium']
init $version: _init_clone
  git config core.sparseCheckout true
  echo 'tools/clang/scripts/' > .git/info/sparse-checkout
  echo 'tools/rust/' >> .git/info/sparse-checkout
  # TODO: remove the following two lines once on a commit at or past:
  # 6dac470f6ba4c6d3859f4d683f805c1a6eedee8a
  echo 'tools/crates/*.py' >> .git/info/sparse-checkout
  echo 'build/*.py' >> .git/info/sparse-checkout
  git checkout "$version"
  git branch -f upstream

[working-directory: 'chromium']
apply-patches:
  # Make sure we're working from a clean state.
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse upstream)" ]]
  git am -3 ../patches/*

[working-directory: 'chromium']
export-patches:
  git format-patch -o ../patches upstream

image:
  "$CONTOOL" build -t cr-toolchain-arm64-builder .

[positional-arguments]
[working-directory: 'chromium']
shell *$args:
  "$CONTOOL" run --security-opt label=disable --rm \
    -i $([[ -t 0 ]] && echo --tty) \
    -v $PWD:/work -w /work \
    cr-toolchain-arm64-builder "$@"

get-llvm-rev:
  #!/bin/bash
  set -ex
  base=$(grep -Po "CLANG_REVISION = '\K[^']+(?='\$)" chromium/tools/clang/scripts/update.py)
  sub=$(grep -Po "CLANG_SUB_REVISION = \K\d+\$" chromium/tools/clang/scripts/update.py)
  echo "$base-$sub"

get-rust-rev:
  #!/bin/bash
  set -ex
  base=$(grep -Po "RUST_REVISION = '\K[^']+(?='\$)" chromium/tools/rust/update_rust.py)
  sub=$(grep -Po "RUST_SUB_REVISION = \K\d+\$" chromium/tools/rust/update_rust.py)
  llvm=$({{quote(just_executable())}} get-llvm-rev | sed -E 's/-[0-9]+$//')
  echo "$base-$sub-$llvm"

get-local-rev-suffix:
  #!/bin/bash
  set -ex
  ncommits=$(git rev-list --count HEAD)
  myrev=$(git rev-parse --short HEAD)
  echo "$ncommits-$myrev"

[working-directory: 'chromium']
build-llvm:
  {{quote(just_executable())}} shell python3 tools/clang/scripts/build.py \
    --disable-asserts --pic \
    --use-system-cmake \
    --no-tools \
    --host-cc=/usr/bin/clang-22 \
    --host-cxx=/usr/bin/clang++-22 \
    --without-android --without-fuchsia --without-zstd \
    --with-ml-inliner-model= \
    --install=/work/third_party/llvm-install
  cp third_party/llvm-build/Release+Asserts/cr_build_revision third_party/llvm-install/

[working-directory: 'chromium/third_party']
_prepare_rust_toolchain_dirs:
  mkdir -p rust-toolchain-intermediate/llvm-host-build
  cp llvm-install/cr_build_revision rust-toolchain-intermediate/llvm-host-build/
  ln -srTf $PWD/llvm-install rust-toolchain-intermediate/llvm-host-install

[working-directory: 'chromium']
build-rust: _prepare_rust_toolchain_dirs
  {{quote(just_executable())}} shell python3 tools/rust/build_rust.py \
    --skip-llvm-build \
    --skip-test

[working-directory: 'chromium']
build-rust-bindgen:
  {{quote(just_executable())}} shell python3 tools/rust/build_bindgen.py \
    --skip-test

[working-directory: 'chromium']
build-rust-crubit:
  {{quote(just_executable())}} shell python3 tools/rust/build_crubit.py

# https://source.chromium.org/chromium/chromium/src/+/main:tools/clang/scripts/package.py;l=1;drc=fc2e8e543698572671a4b6af1410a0ca468addc9
# but we omit the files we're intentionally not building (e.g. other architectures).
[working-directory: 'chromium/third_party/llvm-install']
pack-llvm:
  #!/bin/bash
  set -ex

  files=(
    bin/clang
    bin/lld
    bin/llvm-ar
    bin/llvm-dwp
    bin/llvm-ml
    bin/llvm-nm
    bin/llvm-objcopy
    bin/llvm-pdbutil
    bin/llvm-readobj
    bin/llvm-symbolizer
    bin/llvm-undname
    lib/clang/*/include
    lib/clang/*/lib/aarch64-unknown-linux-gnu/*.a{,.syms}
    lib/clang/*/share
    cr_build_revision
  )

  symlinks=(
    bin/clang++
    bin/ld.lld
    bin/wasm-ld
    bin/llvm-strip
    bin/llvm-install-name-tool
  )

  clangrev=$({{quote(just_executable())}} get-llvm-rev)
  localrev=$({{quote(just_executable())}} get-local-rev-suffix)
  dest={{quote(justfile_directory())}}/clang-"$clangrev"-"$localrev".tar.xz

  [[ "$clangrev" == "$(< ../llvm-build/Release+Asserts/cr_build_revision)" ]]
  [[ "$clangrev" == "$(< ../llvm-install/cr_build_revision)" ]]

  for file in "${files[@]}"; do
    if [[ "$file" == *.a ]]; then
      bin/llvm-strip --keep-file-symbols -g "$file"
    fi
  done

  # use '-h' here to follow links...
  tar -cvhf "$dest" "${files[@]}"
  # ...but omit it for adding things we want to keep as symlinks.
  tar -rvf "$dest" "${symlinks[@]}"

  cd "$(dirname "$dest")"
  sha256sum "$(basename "$dest")" > "$dest.sha256"

# https://source.chromium.org/chromium/chromium/src/+/main:tools/rust/package_rust.py;drc=4d2165ac6386b2c7c9820c566e43d85db0ca09c1
[working-directory: 'chromium/third_party/rust-toolchain']
pack-rust:
  #!/bin/bash
  set -ex

  rustrev=$({{quote(just_executable())}} get-rust-rev)
  localrev=$({{quote(just_executable())}} get-local-rev-suffix)
  dest={{quote(justfile_directory())}}/rust-toolchain-"$rustrev"-"$localrev".tar.xz

  grep -Pq "\b$rustrev\b" VERSION

  for file in bin/* libexec/* lib/rustlib/aarch64-unknown-linux-gnu/{bin/*,lib/*.so}; do
    if [[ "$file" == *.so || "$(head -c 2 "$file")" != "#!" ]]; then
      ../llvm-install/bin/llvm-strip "$file"
    fi
  done

  tar -cvhf "$dest" *

  cd "$(dirname "$dest")"
  sha256sum "$(basename "$dest")" > "$dest.sha256"
