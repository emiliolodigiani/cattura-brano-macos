# Librerie di terze parti (LAME, aubio)

Librerie statiche **arm64** compilate con `MACOSX_DEPLOYMENT_TARGET=14.0`,
incorporate nell'app (nessuna dipendenza da Homebrew a runtime).

Le versioni di Homebrew non vanno bene per la distribuzione: sono
etichettate `minos 26.0` (compilate per il macOS del momento), il linker
avvisa «built for newer macOS version than being linked» e non danno
garanzie sulle versioni di macOS più vecchie che l'app supporta (14.0).

## libmp3lame.a — LAME 3.100

Sorgente: <https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz>

```sh
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0 -O2"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"
./configure --host=aarch64-apple-darwin --disable-shared --enable-static \
            --disable-frontend --disable-decoder --prefix="$PWD/install"
make -j4 && make install
```

## libaubio.a — aubio 0.4.9

Sorgente: <https://aubio.org/pub/aubio-0.4.9.tar.bz2> (il tarball GitHub
non include `waf`).

Configurata **senza** sndfile, avcodec, samplerate, jack e fftw3: la FFT
usa il framework **Accelerate** di sistema (per questo l'app linka
`-framework Accelerate`). L'app usa solo il beat tracker
(`aubio_tempo` + `fvec`), niente I/O di file.

```sh
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0 -O2"
export LINKFLAGS="-arch arm64 -mmacosx-version-min=14.0"
python3 ./waf configure \
  --disable-sndfile --disable-avcodec --disable-samplerate --disable-jack \
  --disable-fftw3 --disable-fftw3f --disable-docs --disable-tests \
  --disable-examples --enable-accelerate
python3 ./waf build --targets=aubio   # fallisce su create_tests_source: innocuo
cd build/src && find . -name "*.o" | sort | xargs libtool -static -o libaubio.a
```

Gli header in `include/` sono quelli pubblici dei rispettivi tarball
(layout identico a quello di Homebrew: `<lame/lame.h>`, `<aubio/aubio.h>`).

Verifica dopo una ricompilazione:

```sh
otool -l lib/libaubio.a | grep -E "minos|platform" | sort -u   # minos 14.0
nm -u lib/libaubio.a | grep -iE "fftw|sndfile|avcodec"          # niente
```
