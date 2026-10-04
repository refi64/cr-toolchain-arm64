FROM debian:trixie
# XXX: we need to install libcurl4-gnutls-dev here, because when cargo is being
# built, its curl-sys dep uses the curl-config from the *host* despite then
# using the libraries from the sysroot.
RUN apt-get update \
  && apt-get install -y cmake curl git libcurl4-gnutls-dev ninja-build pkg-config \
  && echo 'deb http://apt.llvm.org/trixie/ llvm-toolchain-trixie main' > /etc/apt/sources.list.d/llvm.list \
  && curl -L https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc >/dev/null \
  && apt-get update \
  && apt-get install -y clang-22 lld-22 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
