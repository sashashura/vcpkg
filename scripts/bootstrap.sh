#!/bin/sh

# Find .vcpkg-root.
vcpkgRootDir=$(X= cd -- "$(dirname -- "$0")" && pwd -P)
while [ "$vcpkgRootDir" != "/" ] && ! [ -e "$vcpkgRootDir/.vcpkg-root" ]; do
    vcpkgRootDir="$(dirname "$vcpkgRootDir")"
done

# Parse arguments.
vcpkgDisableMetrics="OFF"
vcpkgUseSystem=false
vcpkgUseMuslC="OFF"
for var in "$@"
do
    if [ "$var" = "-disableMetrics" -o "$var" = "--disableMetrics" ]; then
        vcpkgDisableMetrics="ON"
    elif [ "$var" = "-useSystemBinaries" -o "$var" = "--useSystemBinaries" ]; then
        echo "Warning: -useSystemBinaries no longer has any effect; ignored. Note that the VCPKG_USE_SYSTEM_BINARIES environment variable behavior is not changed."
    elif [ "$var" = "-allowAppleClang" -o "$var" = "--allowAppleClang" ]; then
        echo "Warning: -allowAppleClang no longer has any effect; ignored."
    elif [ "$var" = "-buildTests" ]; then
        echo "Warning: -buildTests no longer has any effect; ignored."
    elif [ "$var" = "-musl" ]; then
        vcpkgUseMuslC="ON"
    elif [ "$var" = "-help" -o "$var" = "--help" ]; then
        echo "Usage: ./bootstrap-vcpkg.sh [options]"
        echo
        echo "Options:"
        echo "    -help                Display usage help"
        echo "    -disableMetrics      Mark this vcpkg root to disable metrics."
        echo "    -musl                Use the musl binary rather than the glibc binary on Linux."
        exit 1
    else
        echo "Unknown argument $var. Use '-help' for help."
        exit 1
    fi
done

# Enable using this entry point on windows from git bash by redirecting to the .bat file.
unixName=$(uname -s | sed 's/MINGW.*_NT.*/MINGW_NT/')
if [ "$unixName" = "MINGW_NT" ]; then
    if [ "$vcpkgDisableMetrics" = "ON" ]; then
        args="-disableMetrics"
    else
        args=""
    fi

    vcpkgRootDir=$(cygpath -aw "$vcpkgRootDir")
    cmd "/C $vcpkgRootDir\\bootstrap-vcpkg.bat $args" || exit 1
    exit 0
fi

# Determine the downloads directory.
if [ -z ${VCPKG_DOWNLOADS+x} ]; then
    downloadsDir="$vcpkgRootDir/downloads"
else
    downloadsDir="$VCPKG_DOWNLOADS"
    if [ ! -d "$VCPKG_DOWNLOADS" ]; then
        echo "VCPKG_DOWNLOADS was set to '$VCPKG_DOWNLOADS', but that was not a directory."
        exit 1
    fi

fi

# Check for minimal prerequisites.
vcpkgCheckRepoTool()
{
    __tool=$1
    if ! command -v "$__tool" >/dev/null 2>&1 ; then
        echo "Could not find $__tool. Please install it (and other dependencies) with:"
        echo "On Debian and Ubuntu derivatives:"
        echo "  sudo apt-get install curl zip unzip tar"
        echo "On recent Red Hat and Fedora derivatives:"
        echo "  sudo dnf install curl zip unzip tar"
        echo "On older Red Hat and Fedora derivatives:"
        echo "  sudo yum install curl zip unzip tar"
        echo "On SUSE Linux and derivatives:"
        echo "  sudo zypper install curl zip unzip tar"
        echo "On Arch Linux and derivatives:"
        echo "  sudo pacman -S curl zip unzip tar cmake ninja"
        echo "On Alpine:"
        echo "  apk add build-base cmake ninja zip unzip curl git"
        echo "  (and export VCPKG_FORCE_SYSTEM_BINARIES=1)"
        exit 1
    fi
}

vcpkgCheckRepoTool curl
vcpkgCheckRepoTool zip
vcpkgCheckRepoTool unzip
vcpkgCheckRepoTool tar

UNAME="$(uname)"
ARCH="$(uname -m)"

if [ -e /etc/alpine-release ]; then
    vcpkgUseSystem="ON"
    vcpkgUseMuslC="ON"
fi

if [ "$UNAME" = "OpenBSD" ]; then
    vcpkgUseSystem="ON"

    if [ -z "$CXX" ]; then
        CXX=/usr/bin/clang++
    fi
    if [ -z "$CC" ]; then
        CC=/usr/bin/clang
    fi
fi

if [ "$vcpkgUseSystem" = "ON" ]; then
    vcpkgCheckRepoTool cmake
    vcpkgCheckRepoTool ninja
    vcpkgCheckRepoTool git
    vcpkgCheckRepoTool gcc
fi

# Determine what we are going to do to bootstrap:
# MacOS -> Download vcpkg-macos
# Linux
#   useMuslC -> download vcpkg-muslc
#   amd64 -> download vcpkg-glibc
# Otherwise
#   Download and build from source

# Choose the vcpkg binary to download
vcpkgDownloadTool="ON"
vcpkgToolReleaseTag="2022-08-24"
if [ "$UNAME" = "Darwin" ]; then
    echo "Downloading vcpkg-macos..."
    vcpkgToolReleaseSha="5a5c7af982612d19a5bacf220a356e84a6be2058835e749279c0ac438ee22f23ca3b2e268d390f1b854a56d979b571a62b9cf812ff7087949205efa2988cc29e"
    vcpkgToolName="vcpkg-macos"
elif [ "$vcpkgUseMuslC" = "ON" ]; then
    echo "Downloading vcpkg-muslc..."
    vcpkgToolReleaseSha="337ddbb19d8c94c67c7bb3a6b30c11e7cf585e95d2d09ea2b99d4fda8228e0ef2badc0559d2357da8931eb34c68ec807c959f8bbf9cd282b3d6167a8eb536dff"
    vcpkgToolName="vcpkg-muslc"
elif [ "$ARCH" = "x86_64" ]; then
    echo "Downloading vcpkg-glibc..."
    vcpkgToolReleaseSha="6fc396b53bbe2aeecbd8f4e8a01b5d0fc1304eaa68d5552570de7c2f2176e44e6d5c5ca0ccfe76b50e6d954686c7ec0fc4bf679fd91143bf11952c470be4fde4"
    vcpkgToolName="vcpkg-glibc"
else
    echo "Unable to determine a binary release of vcpkg; attempting to build from source."
    vcpkgDownloadTool="OFF"
    vcpkgToolReleaseSha="a1f934ead84bf5a0526aee05dfb34153313432d078ecfcf122cdd4b68fc06ccc3fe9935d5c94deb696c5678ed173c0b0e7f172b4a896144390171412bb45774d"
fi

# Do the download or build.
vcpkgCheckEqualFileHash()
{
    url=$1; filePath=$2; expectedHash=$3

    if command -v "sha512sum" >/dev/null 2>&1 ; then
        actualHash=$(sha512sum "$filePath")
    else
        # sha512sum is not available by default on osx
        # shasum is not available by default on Fedora
        actualHash=$(shasum -a 512 "$filePath")
    fi

    actualHash="${actualHash%% *}" # shasum returns [hash filename], so get the first word

    if ! [ "$expectedHash" = "$actualHash" ]; then
        echo ""
        echo "File does not have expected hash:"
        echo "              url: [ $url ]"
        echo "        File path: [ $downloadPath ]"
        echo "    Expected hash: [ $sha512 ]"
        echo "      Actual hash: [ $actualHash ]"
        exit 1
    fi
}

vcpkgDownloadFile()
{
    url=$1; downloadPath=$2 sha512=$3
    rm -rf "$downloadPath.part"
    curl -L $url --tlsv1.2 --create-dirs --retry 3 --output "$downloadPath.part" --silent --show-error --fail || exit 1

    vcpkgCheckEqualFileHash $url "$downloadPath.part" $sha512
    chmod +x "$downloadPath.part"
    mv "$downloadPath.part" "$downloadPath"
}

vcpkgExtractTar()
{
    archive=$1; toPath=$2
    rm -rf "$toPath" "$toPath.partial"
    mkdir -p "$toPath.partial"
    $(cd "$toPath.partial" && tar xzf "$archive")
    mv "$toPath.partial" "$toPath"
}

if [ "$vcpkgDownloadTool" = "ON" ]; then
    vcpkgDownloadFile "https://github.com/microsoft/vcpkg-tool/releases/download/$vcpkgToolReleaseTag/$vcpkgToolName" "$vcpkgRootDir/vcpkg" $vcpkgToolReleaseSha
else
    if [ "x$CXX" = "x" ]; then
        if which g++-12 >/dev/null 2>&1; then
            CXX=g++-12
        elif which g++-11 >/dev/null 2>&1; then
            CXX=g++-11
        elif which g++-10 >/dev/null 2>&1; then
            CXX=g++-10
        elif which g++-9 >/dev/null 2>&1; then
            CXX=g++-9
        elif which g++-8 >/dev/null 2>&1; then
            CXX=g++-8
        elif which g++-7 >/dev/null 2>&1; then
            CXX=g++-7
        elif which g++-6 >/dev/null 2>&1; then
            CXX=g++-6
        elif which g++ >/dev/null 2>&1; then
            CXX=g++
        fi
        # If we can't find g++, allow CMake to do the look-up
    fi

    vcpkgToolReleaseTarball="$vcpkgToolReleaseTag.tar.gz"
    vcpkgToolUrl="https://github.com/microsoft/vcpkg-tool/archive/$vcpkgToolReleaseTarball"
    baseBuildDir="$vcpkgRootDir/buildtrees/_vcpkg"
    buildDir="$baseBuildDir/build"
    tarballPath="$downloadsDir/$vcpkgToolReleaseTarball"
    srcBaseDir="$baseBuildDir/src"
    srcDir="$srcBaseDir/vcpkg-tool-$vcpkgToolReleaseTag"

    if [ -e "$tarballPath" ]; then
        vcpkgCheckEqualFileHash "$vcpkgToolUrl" "$tarballPath" "$vcpkgToolReleaseSha"
    else
        echo "Downloading vcpkg tool sources"
        vcpkgDownloadFile "$vcpkgToolUrl" "$tarballPath" "$vcpkgToolReleaseSha"
    fi

    echo "Building vcpkg-tool..."
    rm -rf "$baseBuildDir"
    mkdir -p "$buildDir"
    vcpkgExtractTar "$tarballPath" "$srcBaseDir"
    cmakeConfigOptions="-DCMAKE_BUILD_TYPE=Release -G 'Ninja' -DVCPKG_DEVELOPMENT_WARNINGS=OFF"

    if [ "${VCPKG_MAX_CONCURRENCY}" != "" ] ; then
        cmakeConfigOptions=" $cmakeConfigOptions '-DCMAKE_JOB_POOL_COMPILE:STRING=compile' '-DCMAKE_JOB_POOL_LINK:STRING=link' '-DCMAKE_JOB_POOLS:STRING=compile=$VCPKG_MAX_CONCURRENCY;link=$VCPKG_MAX_CONCURRENCY' "
    fi

    (cd "$buildDir" && CXX="$CXX" eval cmake "$srcDir" $cmakeConfigOptions) || exit 1
    (cd "$buildDir" && cmake --build .) || exit 1

    rm -rf "$vcpkgRootDir/vcpkg"
    cp "$buildDir/vcpkg" "$vcpkgRootDir/"
fi

# Apply the disable-metrics marker file.
if [ "$vcpkgDisableMetrics" = "ON" ]; then
    touch "$vcpkgRootDir/vcpkg.disable-metrics"
elif ! [ -f "$vcpkgRootDir/vcpkg.disable-metrics" ]; then
    # Note that we intentionally leave any existing vcpkg.disable-metrics; once a user has
    # opted out they should stay opted out.
    cat <<EOF
Telemetry
---------
vcpkg collects usage data in order to help us improve your experience.
The data collected by Microsoft is anonymous.
You can opt-out of telemetry by re-running the bootstrap-vcpkg script with -disableMetrics,
passing --disable-metrics to vcpkg on the command line,
or by setting the VCPKG_DISABLE_METRICS environment variable.

Read more about vcpkg telemetry at docs/about/privacy.md
EOF
fi
