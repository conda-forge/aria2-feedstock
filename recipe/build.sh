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
  export PKG_CONFIG_DONT_DEFINE_PREFIX=1
  export PKG_CONFIG_PATH="$(cygpath -m "${PREFIX}/lib/pkgconfig");$(cygpath -m "${PREFIX}/share/pkgconfig")"

  # Compiler definitions
  WIN_FLAGS="-DWIN32 -D_WIN32 -D_WIN32_WINNT=0x0601 -D__MINGW32__ -DNOMINMAX -D_CRT_NONSTDC_NO_DEPRECATE -D__MINGW_PRINTF_FORMAT=printf -Wno-deprecated-literal-operator -Wno-ignored-attributes -Wno-deprecated-declarations"
  export CPPFLAGS="${CPPFLAGS} ${WIN_FLAGS}"
  export CXXFLAGS="${CXXFLAGS} ${WIN_FLAGS}"
  export CFLAGS="${CFLAGS} ${WIN_FLAGS}"

  # 1. Header compatibility shims
  mkdir -p win_compat/sys

  cat << 'EOF' > win_compat/sys/time.h
#ifndef _WIN_COMPAT_SYS_TIME_H
#define _WIN_COMPAT_SYS_TIME_H
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <time.h>
#ifdef __cplusplus
extern "C" {
#endif
int gettimeofday(struct timeval *tp, void *tzp);
char* asctime_r(const struct tm *tm, char *buf);
struct tm* localtime_r(const time_t *clock, struct tm *result);
time_t timegm(struct tm *tm);
#ifdef __cplusplus
}
#endif
#endif
EOF

  cat << 'EOF' > win_compat/strings.h
#ifndef _WIN_COMPAT_STRINGS_H
#define _WIN_COMPAT_STRINGS_H
#include <string.h>
#ifndef strcasecmp
#define strcasecmp _stricmp
#endif
#ifndef strncasecmp
#define strncasecmp _strnicmp
#endif
#endif
EOF

  cat << 'EOF' > win_compat/unistd.h
#ifndef _WIN_COMPAT_UNISTD_H
#define _WIN_COMPAT_UNISTD_H
#include <io.h>
#include <process.h>
#include <direct.h>
#include <stdlib.h>
#include <stdio.h>
#ifndef STDIN_FILENO
#define STDIN_FILENO 0
#endif
#ifndef STDOUT_FILENO
#define STDOUT_FILENO 1
#endif
#ifndef STDERR_FILENO
#define STDERR_FILENO 2
#endif
#ifndef F_OK
#define F_OK 0
#endif
#ifndef W_OK
#define W_OK 2
#endif
#ifndef R_OK
#define R_OK 4
#endif
#ifndef X_OK
#define X_OK 0
#endif
#ifndef getpid
#define getpid _getpid
#endif
#ifndef setenv
#define setenv(k, v, o) _putenv_s(k, v)
#endif
#ifndef unsetenv
#define unsetenv(k) _putenv_s(k, "")
#endif
#ifdef __cplusplus
extern "C" {
#endif
static inline int close(int fd) { return _close(fd); }
static inline int read(int fd, void *buf, unsigned int count) { return _read(fd, buf, count); }
static inline int write(int fd, const void *buf, unsigned int count) { return _write(fd, buf, count); }
static inline long lseek(int fd, long offset, int origin) { return _lseek(fd, offset, origin); }
static inline int unlink(const char *pathname) { return _unlink(pathname); }
static inline int isatty(int fd) { return _isatty(fd); }
static inline int fileno(FILE *stream) { return _fileno(stream); }
static inline int rmdir(const char *pathname) { return _rmdir(pathname); }
#ifdef __cplusplus
}
#endif
#endif
EOF

  cat << 'EOF' > win_compat/getopt.h
#ifndef _WIN_COMPAT_GETOPT_H
#define _WIN_COMPAT_GETOPT_H

#define no_argument        0
#define required_argument  1
#define optional_argument  2

struct option {
  const char *name;
  int has_arg;
  int *flag;
  int val;
};

#ifdef __cplusplus
extern "C" {
#endif

extern char *optarg;
extern int optind, opterr, optopt;

int getopt(int argc, char *const argv[], const char *optstring);
int getopt_long(int argc, char *const argv[], const char *optstring,
                const struct option *longopts, int *longindex);

#ifdef __cplusplus
}
#endif

#endif
EOF

  WIN_COMPAT_DIR="$(cygpath -m "$(pwd)/win_compat")"
  export CPPFLAGS="-I${WIN_COMPAT_DIR} ${CPPFLAGS}"
  export CXXFLAGS="-I${WIN_COMPAT_DIR} ${CXXFLAGS}"
  export CFLAGS="-I${WIN_COMPAT_DIR} ${CFLAGS}"

  # 2. Provide getopt implementation source
  cat << 'EOF' > src/getopt.c
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "getopt.h"

char *optarg = NULL;
int optind = 1;
int opterr = 1;
int optopt = '?';

int getopt_long(int argc, char *const argv[], const char *optstring,
                const struct option *longopts, int *longindex) {
  if (optind >= argc || argv[optind] == NULL) {
    return -1;
  }
  char *arg = argv[optind];
  if (arg[0] != '-' || arg[1] == '\0') {
    return -1;
  }
  if (arg[0] == '-' && arg[1] == '-' && arg[2] == '\0') {
    optind++;
    return -1;
  }
  if (arg[1] == '-') {
    const char *name = arg + 2;
    const char *equal = strchr(name, '=');
    size_t namelen = equal ? (size_t)(equal - name) : strlen(name);
    for (int i = 0; longopts && longopts[i].name; i++) {
      if (strncmp(longopts[i].name, name, namelen) == 0 && longopts[i].name[namelen] == '\0') {
        if (longindex) *longindex = i;
        if (longopts[i].has_arg == 1) {
          if (equal) {
            optarg = (char*)(equal + 1);
          } else if (optind + 1 < argc) {
            optind++;
            optarg = argv[optind];
          } else {
            optopt = longopts[i].val;
            return optstring && optstring[0] == ':' ? ':' : '?';
          }
        } else if (longopts[i].has_arg == 2) {
          optarg = equal ? (char*)(equal + 1) : NULL;
        } else {
          if (equal) return '?';
          optarg = NULL;
        }
        optind++;
        if (longopts[i].flag) {
          *(longopts[i].flag) = longopts[i].val;
          return 0;
        }
        return longopts[i].val;
      }
    }
    optind++;
    return '?';
  } else {
    char c = arg[1];
    const char *p = optstring ? strchr(optstring, c) : NULL;
    if (!p || c == ':') {
      optopt = c;
      optind++;
      return '?';
    }
    if (p[1] == ':') {
      if (arg[2] != '\0') {
        optarg = arg + 2;
      } else if (optind + 1 < argc) {
        optind++;
        optarg = argv[optind];
      } else {
        optopt = c;
        optind++;
        return optstring[0] == ':' ? ':' : '?';
      }
    } else {
      optarg = NULL;
    }
    optind++;
    return c;
  }
}

int getopt(int argc, char *const argv[], const char *optstring) {
  return getopt_long(argc, argv, optstring, NULL, NULL);
}
EOF

  # 3. Patch gai_strerror.h and gai_strerror.c (compiled automatically by autotools via LIBOBJS)
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

  # 4. Source adjustments for C++20 and UCRT compliance
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

  # Keep LIBS strictly to system libraries for ./configure
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
