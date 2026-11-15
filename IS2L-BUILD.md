# Building is2l Remote

These are the steps this repository's CI uses (`.github/workflows/flutter-build.yml`, `.github/workflows/bridge.yml`, `flutter/build_android_deps.sh`, `flutter/ndk_arm64.sh`, `build.py`), written out for a local Linux x86_64 machine. They have **not** been run for this fork; nothing here has been built yet.

Run every command from the repository root unless a step says otherwise. Clone with submodules (`libs/hbb_common` is one):

```sh
git submodule update --init --recursive
```

## Versions pinned by CI

| Tool | Version |
| --- | --- |
| Rust | 1.75 |
| Flutter (Android app and Linux x86_64 host) | 3.24.5 |
| Flutter used only to generate the bridge | 3.22.3 |
| flutter_rust_bridge_codegen | 1.80.1 (with feature `uuid`) |
| cargo-expand | 1.0.95 |
| Android NDK | r28c |
| cargo-ndk | 3.1.2 |
| vcpkg | commit `9e593bb18ea69cc5095e012465dcd675a822ed0d` |
| JDK (Android) | OpenJDK 17 |
| App version | 1.5.3 |

CI builds the Android app on Ubuntu 24.04 and the Linux host inside an Ubuntu 18.04 container (so the result runs on old distributions). A local build on a current distribution only runs on that distribution or newer.

## 1. Common setup

Rust:

```sh
rustup toolchain install 1.75 --component rustfmt
rustup default 1.75
```

vcpkg at the pinned commit (CI puts it in `/opt/artifacts/vcpkg`; any path works):

```sh
git clone https://github.com/microsoft/vcpkg /opt/artifacts/vcpkg
git -C /opt/artifacts/vcpkg checkout 9e593bb18ea69cc5095e012465dcd675a822ed0d
/opt/artifacts/vcpkg/bootstrap-vcpkg.sh
export VCPKG_ROOT=/opt/artifacts/vcpkg
```

CI notes that this vcpkg version needs CMake 4.3 or newer on some runners (`VCPKG_CMAKE_VERSION: "4.3.0"`).

Flutter 3.24.5, with the one patch CI applies to it:

```sh
wget https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz
tar xf flutter_linux_3.24.5-stable.tar.xz -C /opt
export PATH=/opt/flutter/bin:$PATH
git -C /opt/flutter apply "$PWD/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
```

## 2. Generate the bridge (after every change to `src/flutter_ffi.rs`)

The Dart side calls Rust through files that are generated, not stored in the repository: `src/bridge_generated.rs`, `src/bridge_generated.io.rs`, `flutter/lib/generated_bridge.dart`, `flutter/lib/generated_bridge.freezed.dart` and `flutter/macos/Runner/bridge_generated.h`. This fork adds `session_send_gamepad` and `session_peer_supports_gamepad` to `src/flutter_ffi.rs`, so the bridge must be generated before either the app or the host is built.

Packages CI installs for this job:

```sh
sudo apt-get install -y clang cmake curl gcc git g++ libclang-dev libgtk-3-dev llvm-dev nasm ninja-build pkg-config wget
```

CI generates the bridge with Flutter 3.22.3 and, for that Flutter only, lowers one dependency so that `flutter pub get` resolves:

```sh
cargo install cargo-expand --version 1.0.95 --locked
cargo install flutter_rust_bridge_codegen --version 1.80.1 --features "uuid" --locked

# with Flutter 3.22.3 first in PATH:
sed -i -e 's/extended_text: 14.0.0/extended_text: 13.0.0/g' flutter/pubspec.yaml
pushd flutter && flutter pub get && popd

~/.cargo/bin/flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h
cp ./flutter/macos/Runner/bridge_generated.h ./flutter/ios/Runner/bridge_generated.h
```

In CI that edit of `flutter/pubspec.yaml` stays inside the bridge job; the build jobs start from a clean checkout and only receive the generated files. Locally, put the line back before building the app:

```sh
sed -i -e 's/extended_text: 13.0.0/extended_text: 14.0.0/g' flutter/pubspec.yaml
```

## 3. Android client (application id `com.isleep2late.remote`)

Packages CI installs:

```sh
sudo apt-get install -y clang cmake curl gcc-multilib git g++ g++-multilib \
  libayatana-appindicator3-dev libasound2-dev libc6-dev libclang-dev libunwind-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgtk-3-dev libpulse-dev libva-dev \
  libxcb-randr0-dev libxcb-shape0-dev libxcb-xfixes0-dev libxdo-dev libxfixes-dev \
  llvm-dev nasm ninja-build openjdk-17-jdk-headless pkg-config tree wget
```

Install Android NDK r28c and the Android SDK, then:

```sh
export ANDROID_NDK_HOME=/path/to/android-ndk-r28c
export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
```

CI first checks a rule this fork must keep: every Android native function is declared in `ffi.FFI` (`flutter/android/app/src/main/kotlin/ffi.kt`) and exported from Rust as `Java_ffi_FFI_*`, and Rust never looks up `com/carriez` classes by name. The check, as CI runs it (it must print nothing):

```sh
grep -rnE --include='*.rs' 'fn Java_' src libs | grep -v 'fn Java_ffi_FFI_'
grep -rl --include='*.kt' 'external fun' flutter/android | grep -vx 'flutter/android/app/src/main/kotlin/ffi.kt'
grep -rn --include='*.rs' 'com/carriez' src libs
```

Native dependencies through vcpkg, for a 64-bit ARM device (AYN Thor, current phones):

```sh
./flutter/build_android_deps.sh arm64-v8a
```

The Rust library:

```sh
rustup target add aarch64-linux-android
cargo install cargo-ndk --version 3.1.2 --locked
./flutter/ndk_arm64.sh
```

`flutter/ndk_arm64.sh` runs `cargo ndk --platform 21 --target aarch64-linux-android build --locked --release --features flutter,hwcodec`.

Copy the library and the C++ runtime where the app expects them:

```sh
mkdir -p ./flutter/android/app/src/main/jniLibs/arm64-v8a
cp ./target/aarch64-linux-android/release/liblibrustdesk.so ./flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so
cp ${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so ./flutter/android/app/src/main/jniLibs/arm64-v8a/
```

The APK (JDK 17):

```sh
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH
sed -i "s/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx2g/g" ./flutter/android/gradle.properties
pushd flutter
flutter build apk --release --target-platform android-arm64 --split-per-abi
popd
```

Result: `flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.

Signing. The release build type in `flutter/android/app/build.gradle` uses `signingConfigs.release`, which reads `flutter/android/key.properties` (`keyAlias`, `keyPassword`, `storeFile`, `storePassword`). CI instead switches the build to the debug key and signs the APK afterwards with its own secret key:

```sh
sed -i "s/signingConfigs.release/signingConfigs.debug/g" ./flutter/android/app/build.gradle
```

Use one key for every release of the fork: Android refuses to update an installed app with an APK signed by a different key. Because the application id is `com.isleep2late.remote`, the key does not have to be RustDesk's, and the app installs beside stock RustDesk.

For 32-bit ARM or x86_64 devices CI uses `armeabi-v7a` with `./flutter/ndk_arm.sh` and `--target-platform android-arm`, or `x86_64` with `./flutter/ndk_x64.sh` and `--target-platform android-x64`, in the same way.

## 4. Linux host (x86_64)

Packages CI installs inside its build container (CI uses `libclang-10-dev` and `llvm-10-dev` there because the container is Ubuntu 18.04; on a current distribution use `libclang-dev` and `llvm-dev`):

```sh
sudo apt-get install -y build-essential clang cmake curl gcc git g++ \
  libayatana-appindicator3-dev libasound2-dev libclang-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgtk-3-dev libpulse-dev libva-dev \
  libxcb-randr0-dev libxcb-shape0-dev libxcb-xfixes0-dev libxdo-dev libxfixes-dev \
  llvm-dev nasm ninja-build pkg-config tree python3 rpm unzip wget xz-utils libssl-dev
```

Native dependencies through vcpkg:

```sh
$VCPKG_ROOT/vcpkg install --triplet x64-linux --x-install-root="$VCPKG_ROOT/installed"
```

CI builds only the shared library form of the Rust crate:

```sh
sed -i "s/\[\"cdylib\", \"staticlib\", \"rlib\"\]/\[\"cdylib\"\]/g" Cargo.toml
```

The Rust library, then the Flutter app and the `.deb` package:

```sh
cargo build --locked --lib --features hwcodec,flutter,unix-file-copy-paste --release

export CARGO_INCREMENTAL=0
export DEB_ARCH=amd64
python3 ./build.py --flutter --skip-cargo
```

`build.py` runs `flutter build linux --release` and packs the result, together with `res/rustdesk.service`, into `rustdesk-1.5.3.deb` in the repository root. Install it with `sudo apt install ./rustdesk-1.5.3.deb`. The package is still named `rustdesk` in this round, so it replaces a stock RustDesk on that PC. Installing the package sets up the `rustdesk` service, which runs as root and is the part that creates the virtual game controller.

## AGPL-3.0

RustDesk is licensed under the GNU Affero General Public License, version 3 (`LICENCE`), and so is this fork. Two duties follow. First, anyone you give the app or the host program to must be able to get the complete source of exactly that version, including the changes made here, under the same licence. Second, because of the "Affero" part, anyone who connects over a network to a host running the modified program must also be offered that source. In practice: keep this repository available to those people (a link in the app's About page, in the release notes, or sent on request is enough), keep the licence file and the existing copyright notices, and state that the program was modified and when.
