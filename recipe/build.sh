#!/bin/bash
set -ex

# 0. Ensure source tree is unpacked and located at current root
if [ -f aria2-*.tar.gz ]; then
  tar -xzf aria2-*.tar.gz --strip-components=1
fi
if [ ! -d "src" ] && [ -d aria2-* ]; then
  mv aria2-*/* .
fi
mkdir -p src

OSX_ARGS=""
WIN_ARGS=""
CONFIG_SHARED_ARGS="--enable-libaria2"

if [ "$(uname)" == "Darwin" ]; then
  OSX_ARGS="--with-libgmp"
fi

TLS_ARGS="--with-openssl"

if [[ "${target_platform}" == win-* ]]; then
  # 1. Apply Windows compatibility patch
  patch -p1 --binary < "${RECIPE_DIR}/patches/0001-windows-msvc-support.patch"

  # 2. Fix gai_strerror.h and gai_strerror.c
  cat << 'EOF' > src/gai_strerror.h
#ifndef D_GAI_STRERROR_H
#define D_GAI_STRERROR_H
#ifdef __cplusplus
extern "C" {
#endif
#ifdef gai_strerror
#undef gai_strerror
#endif
const char* gai_strerror(int errcode);
#ifdef __cplusplus
}
#endif
#endif
EOF

  cat << 'EOF' > src/gai_strerror.c
#include "gai_strerror.h"
#include <stdio.h>
#ifdef __cplusplus
extern "C" {
#endif
const char* gai_strerror(int errcode) {
  static char buf[128];
  snprintf(buf, sizeof(buf), "getaddrinfo error %d", errcode);
  return buf;
}
#ifdef __cplusplus
}
#endif
EOF

  # 3. Source adjustments for C++20 and UCRT compliance
  sed -i.bak '1s/^/#include <string.h>\n#include <time.h>\n#define strncasecmp _strnicmp\n#define strcasecmp _stricmp\n#define tzname _tzname\n#define tzset _tzset\n/' src/strptime.c
  sed -i.bak 's/struct timespec {/#if !defined(_WIN32) \&\& !defined(__MINGW32__)\nstruct timespec {/g' src/timespec.h
  sed -i.bak 's/};/};\n#endif/g' src/timespec.h

  if [ -f src/common.h ]; then
    sed -i.bak '1s/^/#include <sys\/stat.h>\n#include <iterator>\n#ifndef S_ISREG\n#define S_ISREG(m) (((m) \& _S_IFMT) == _S_IFREG)\n#endif\n#ifndef S_ISDIR\n#define S_ISDIR(m) (((m) \& _S_IFMT) == _S_IFDIR)\n#endif\n/' src/common.h
  fi
  sed -i.bak '1s/^/#include <iterator>\n/' src/RpcMethodImpl.h
  sed -i.bak 's/std::end(buf_) - last_/buf_.data() + buf_.size() - last_/g' src/SocketRecvBuffer.cc

  sed -i.bak 's/-Wl,--dynamicbase//g' configure
  sed -i.bak 's/-Wl,--nxcompat//g' configure

  export PKG_CONFIG_DONT_DEFINE_PREFIX=1
  export PKG_CONFIG_PATH="$(cygpath -m "${PREFIX}/lib/pkgconfig");$(cygpath -m "${PREFIX}/share/pkgconfig")"

  WIN_FLAGS="-DWIN32 -D_WIN32 -D_WIN32_WINNT=0x0601 -D__MINGW32__ -DNOMINMAX -D_CRT_NONSTDC_NO_DEPRECATE -D__MINGW_PRINTF_FORMAT=printf -Wno-deprecated-literal-operator -Wno-ignored-attributes -Wno-deprecated-declarations"
  WIN_COMPAT_DIR="$(cygpath -m "$(pwd)/win_compat")"
  export CPPFLAGS="-I${WIN_COMPAT_DIR} ${CPPFLAGS} ${WIN_FLAGS}"
  export CXXFLAGS="-I${WIN_COMPAT_DIR} ${CXXFLAGS} ${WIN_FLAGS}"
  export CFLAGS="-I${WIN_COMPAT_DIR} ${CFLAGS} ${WIN_FLAGS}"

  export LIBS="-lws2_32 -liphlpapi -luserenv -lcrypt32 -ladvapi32 -lsecur32 -lbcrypt -lshell32 -loldnames ${LIBS}"
  TLS_ARGS="--without-openssl --without-gnutls --with-wintls --with-libgmp"
  CONFIG_SHARED_ARGS="--disable-shared --enable-static --disable-libaria2"
  WIN_ARGS="ac_cv_header_winsock2_h=yes ac_cv_header_ws2tcpip_h=yes ac_cv_header_windows_h=yes ac_cv_header_sys_time_h=yes ac_cv_header_strings_h=yes ac_cv_header_unistd_h=yes ac_cv_header_sys_socket_h=no ac_cv_header_sys_select_h=no ac_cv_header_arpa_inet_h=no ac_cv_header_netinet_in_h=no ac_cv_header_netinet_tcp_h=no ac_cv_header_netdb_h=no ac_cv_header_pwd_h=no ac_cv_func_select=yes ac_cv_func_socket=yes ac_cv_func_getaddrinfo=yes ac_cv_struct_timespec=yes ac_cv_type_struct_timespec=yes"
fi

./configure --prefix="${PREFIX}" \
            --bindir="${PREFIX}/bin" \
            --sbindir="${PREFIX}/bin" \
            --libdir="${PREFIX}/lib" \
            --includedir="${PREFIX}/include" \
            --disable-dependency-tracking \
            ${TLS_ARGS} \
            --with-libz \
            --with-libxml2 \
            --with-libssh2 \
            --with-libcares \
            --with-sqlite3 \
            ${CONFIG_SHARED_ARGS} \
            ${OSX_ARGS} \
            ${WIN_ARGS}

if [[ "${target_platform}" == win-* ]]; then
  patch_libtool

  find . -name "config.h" -exec sed -i.bak \
    -e 's/\/\* #undef HAVE_STRUCT_TIMESPEC \*\//#define HAVE_STRUCT_TIMESPEC 1/g' \
    {} +
fi

make -j${CPU_COUNT} || true

if [[ "${target_platform}" == win-* ]]; then
  # Compile getopt.c so it is collected into aria2c_objs.rsp
  $CC $CFLAGS -c src/getopt.c -o src/getopt.o

  if [ ! -f src/aria2c.exe ]; then
    echo "Directly linking aria2c.exe from compiled objects..."

    find src deps/wslay/lib -name "*.o" ! -name "main.o" | while read -r f; do
      cygpath -m "$f"
    done > src/aria2c_objs.rsp

    LIB_DIR_1="$(cygpath -m "${PREFIX}/lib")"
    LIB_DIR_2="$(cygpath -m "${PREFIX}/Library/lib")"

    $CXX $CXXFLAGS $LDFLAGS \
      src/main.o @src/aria2c_objs.rsp \
      -L"${LIB_DIR_1}" -L"${LIB_DIR_2}" \
      -lz -lxml2 -lssh2 -lcares -lsqlite3 -lgmp \
      $LIBS \
      -o src/aria2c.exe
  fi
fi

make install || true

if [[ "${target_platform}" == win-* ]]; then
  mkdir -p "${PREFIX}/bin"
  if [ -f src/aria2c.exe ]; then
    cp src/aria2c.exe "${PREFIX}/bin/aria2c.exe"
  fi
  if [ -d "${PREFIX}/lib" ]; then
    mv "${PREFIX}/lib"/*.dll "${PREFIX}/bin/" 2>/dev/null || true
  fi
fi
