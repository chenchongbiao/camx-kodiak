#!/bin/bash

set -euo pipefail

CAMX_VERSION="1.0.25"
PBT_BUILD_DATE="260708"
PBT_BRANCH="master"
BASE_URL="${CAMX_BASE_URL:-https://qartifactory-edge.qualcomm.com/artifactory/qsc_releases/software/chip/component/camx.qclinux.0.0/${PBT_BUILD_DATE}/prebuilt_yocto_${PBT_BRANCH}}"
ARCH="armv8-2a"
CACHE_DIR="${CAMX_CACHE_DIR:-.}"

CAMXLIB_ARCHIVE="camxlib-kodiak_${CAMX_VERSION}_${ARCH}.tar.gz"
CAMX_ARCHIVE="camx-kodiak_${CAMX_VERSION}_${ARCH}.tar.gz"
CHICDK_ARCHIVE="chicdk-kodiak_${CAMX_VERSION}_${ARCH}.tar.gz"

# SHA256 of the three verified 1.0.25 Kodiak archives.
# camxlib must match the artifact published at the pinned URL
# (Content-Length 110426645); it is the only variant that ships
# usr/lib/camx/kodiak/com.qti.stats.common.so.0, which the 3A stats
# components load at runtime.
CAMXLIB_SHA256="c8bc1baab12d2002a3a614b28c045868693a3a59a003b25b8a9236a0df7e941e"
CAMX_SHA256="46a1d3d0682beb931e44cccdd47834b59a54004908441e4597ad11ced4f5d0c8"
CHICDK_SHA256="386f7cb21feffeb9ede8430e58c837f47ed988bc3980b3a7f2430dfbc67ae785"

CAMXLIB_STAGE="camxlib-kodiak"
CAMX_STAGE="camx-kodiak"
CHICDK_STAGE="chicdk-kodiak"
CHICDK_IMX577_STAGE="chicdk-kodiak-imx577"
CHICDK_IMX415_STAGE="chicdk-kodiak-imx415"

fetch_archive() {
    local archive="$1"
    local sha256="$2"
    local output="${CACHE_DIR}/${archive}"

    mkdir -p "$CACHE_DIR"
    if [[ -f "$output" ]] && printf '%s  %s\n' "$sha256" "$output" | sha256sum -c - 2>/dev/null; then
        echo "Using existing verified archive ${output}"
        return 0
    fi

    local temporary="${output}.tmp"
    echo "Downloading ${archive} to ${temporary}"
    wget --tries=5 --timeout=120 --wait=3 \
        -O "$temporary" "${BASE_URL}/${archive}"

    echo "Checking ${temporary}"
    printf '%s  %s\n' "$sha256" "$temporary" | sha256sum -c -
    mv -f "$temporary" "$output"
}

unpack_archive() {
    local archive="$1"
    local temporary="$2"
    tar --no-same-owner -xzf "${CACHE_DIR}/${archive}" -C "$temporary"

    if [[ -d "$temporary/usr" ]]; then
        printf '%s\n' "$temporary"
        return
    fi

    local root
    root="$(find "$temporary" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    if [[ -z "$root" || ! -d "$root/usr" ]]; then
        echo "ERROR: ${archive} does not contain a top-level usr directory" >&2
        return 1
    fi
    printf '%s\n' "$root"
}

reset_stage() {
    local stage="$1"
    rm -rf "$stage"
    mkdir -p "$stage/usr"
}

copy_library() {
    local source="$1"
    local destination="$2"
    # Skip unversioned development symlinks (${SOLIBSDEV}). The runtime
    # packages ship only the SONAME links, matching the Yocto packaging.
    if [[ "$(basename "$source")" == *.so ]]; then
        return 0
    fi
    if [[ -L "$source" ]]; then
        ln -s "$(readlink "$source")" "${destination}/$(basename "$source")"
    elif [[ -f "$source" ]]; then
        install -m 0755 "$source" "$destination/"
    fi
}

copy_common_docs() {
    local source_usr="$1"
    local package="$2"
    local destination="${package}/usr/share/doc/${package}"

    mkdir -p "$destination"
    if [[ -f "${source_usr}/share/doc/camxlib-kodiak/NOTICE" ]]; then
        install -D -m 0644 "${source_usr}/share/doc/camxlib-kodiak/NOTICE" "$destination/NOTICE"
    fi
    if [[ -f "${source_usr}/share/doc/camxlib-kodiak/LICENSE.QCOM-2.txt" ]]; then
        install -D -m 0644 "${source_usr}/share/doc/camxlib-kodiak/LICENSE.QCOM-2.txt" "$destination/LICENSE.QCOM-2.txt"
    fi
}

stage_camxlib() {
    local source_usr="$1"
    reset_stage "$CAMXLIB_STAGE"

    # Ship only headers from the matching 1.0.25 release archive.
    if [[ -d "${source_usr}/include" ]]; then
        mkdir -p "${CAMXLIB_STAGE}/usr/include"
        cp -a "${source_usr}/include/." "${CAMXLIB_STAGE}/usr/include/"
    fi

    # Shared CamX libraries.
    mkdir -p "${CAMXLIB_STAGE}/usr/lib"
    if [[ -d "${source_usr}/lib" ]]; then
        for file in "${source_usr}/lib"/lib*; do
            copy_library "$file" "${CAMXLIB_STAGE}/usr/lib"
        done
    fi
    # Install CamX runtime libraries from the camxlib-kodiak archive.
    # CHI node libraries are owned by camx-kodiak (com.qti.node.eisv*,
    # com.qti.node.swregistration*) and chicdk-kodiak (all other
    # com.qti.node*), so they are never staged from camxlib.
    if [[ -d "${source_usr}/lib/camx/kodiak" ]]; then
        mkdir -p "${CAMXLIB_STAGE}/usr/lib/camx/kodiak" "${CAMXLIB_STAGE}/usr/lib/camx/kodiak/camera/components"
        for file in "${source_usr}/lib/camx/kodiak"/*.so*; do
            copy_library "$file" "${CAMXLIB_STAGE}/usr/lib/camx/kodiak"
        done
        # OpenCL SHDR kernels are shipped by the Yocto image and are loaded
        # at runtime by the ImageIPE/SHDR path.
        for file in "${source_usr}/lib/camx/kodiak"/*.cl; do
            [[ -f "$file" ]] || continue
            install -m 0644 "$file" "${CAMXLIB_STAGE}/usr/lib/camx/kodiak/"
        done
        for file in "${source_usr}/lib/camx/kodiak/camera/components"/*.so*; do
            case "$(basename "$file")" in
                com.qti.node*) continue ;;
            esac
            copy_library "$file" "${CAMXLIB_STAGE}/usr/lib/camx/kodiak/camera/components"
        done
    fi

    # Package documentation and Qualcomm license files.
    if [[ -d "${source_usr}/share/doc/camxlib-kodiak" ]]; then
        mkdir -p "${CAMXLIB_STAGE}/usr/share/doc/camxlib-kodiak"
        for file in "${source_usr}/share/doc/camxlib-kodiak"/*; do
            [[ -f "$file" ]] || continue
            install -m 0644 "$file" "${CAMXLIB_STAGE}/usr/share/doc/camxlib-kodiak/"
        done
    fi
    copy_common_docs "$source_usr" "$CAMXLIB_STAGE"
}

stage_camx() {
    local source_usr="$1"
    reset_stage "$CAMX_STAGE"

    # CamX public libraries and the Kodiak runtime directory.
    mkdir -p "${CAMX_STAGE}/usr/lib" "${CAMX_STAGE}/usr/lib/camx/kodiak/hw" \
        "${CAMX_STAGE}/usr/lib/camx/kodiak/camera/components"
    for file in \
        "${source_usr}/lib"/libcamx_hardware_kodiak.so* \
        "${source_usr}/lib"/libcamxexternalformatutils_kodiak.so*; do
        copy_library "$file" "${CAMX_STAGE}/usr/lib"
    done
    for file in \
        "${source_usr}/lib/camx/kodiak"/libchilog.so* \
        "${source_usr}/lib/camx/kodiak"/libcamera_hardware.so* \
        "${source_usr}/lib/camx/kodiak"/libcamxexternalformatutils.so* \
        "${source_usr}/lib/camx/kodiak"/libcamximageformatutils.so* \
        "${source_usr}/lib/camx/kodiak"/libofflinedump.so* \
        "${source_usr}/lib/camx/kodiak"/com.qti.settings.kodiak.so* \
        "${source_usr}/lib/camx/kodiak"/libcom.qti.node.eisv.so*; do
        copy_library "$file" "${CAMX_STAGE}/usr/lib/camx/kodiak"
    done
    # CHI node libraries owned by camx-kodiak: the EIS nodes and the
    # software registration node, plus the common CHI IQ utilities.
    for file in \
        "${source_usr}/lib/camx/kodiak/camera/components"/com.qti.node.eisv*.so* \
        "${source_usr}/lib/camx/kodiak/camera/components"/com.qti.node.swregistration.so* \
        "${source_usr}/lib/camx/kodiak/camera/components"/libcom.qti.camx.chiiqutils.so*; do
        copy_library "$file" "${CAMX_STAGE}/usr/lib/camx/kodiak/camera/components"
    done
    for file in "${source_usr}/lib/camx/kodiak/hw"/camera.qcom.so*; do
        copy_library "$file" "${CAMX_STAGE}/usr/lib/camx/kodiak/hw"
    done

    # Package documentation and Qualcomm license files.
    if [[ -d "${source_usr}/share/doc/camx-kodiak" ]]; then
        mkdir -p "${CAMX_STAGE}/usr/share/doc/camx-kodiak"
        for file in "${source_usr}/share/doc/camx-kodiak"/*; do
            [[ -f "$file" ]] || continue
            install -m 0644 "$file" "${CAMX_STAGE}/usr/share/doc/camx-kodiak/"
        done
    fi
    copy_common_docs "$source_usr" "$CAMX_STAGE"
}

stage_chicdk() {
    local source_usr="$1"
    reset_stage "$CHICDK_STAGE"

    # CHI/CDK feature libraries and hardware components.
    mkdir -p "${CHICDK_STAGE}/usr/lib/camx/kodiak/hw"
    for file in \
        "${source_usr}/lib/camx/kodiak"/com.qti.feature2*.so* \
        "${source_usr}/lib/camx/kodiak"/libchimldw*.so* \
        "${source_usr}/lib/camx/kodiak"/com.qualcomm*.so* \
        "${source_usr}/lib/camx/kodiak"/chiofflinepostproclib*.so* \
        "${source_usr}/lib/camx/kodiak"/libcommonchiutils*.so* \
        "${source_usr}/lib/camx/kodiak"/libiccprofile*.so* \
        "${source_usr}/lib/camx/kodiak"/com.qti.chiusecaseselector*.so* \
        "${source_usr}/lib/camx/kodiak"/libchicustomization.so*; do
        copy_library "$file" "${CHICDK_STAGE}/usr/lib/camx/kodiak"
    done
    for file in "${source_usr}/lib/camx/kodiak/hw"/com.qti.chi.*.so*; do
        copy_library "$file" "${CHICDK_STAGE}/usr/lib/camx/kodiak/hw"
    done

    # Sensor modules, tuning binaries, and CHI node components.
    mkdir -p "${CHICDK_STAGE}/usr/lib/camx/kodiak/camera/components" "${CHICDK_STAGE}/usr/lib/camx/kodiak/camera"
    for file in "${source_usr}/lib/camx/kodiak/camera/components"/*.so*; do
        copy_library "$file" "${CHICDK_STAGE}/usr/lib/camx/kodiak/camera/components"
    done
    for file in "${source_usr}/lib/camx/kodiak/camera"/*.bin; do
        [[ -f "$file" ]] || continue
        install -m 0644 "$file" "${CHICDK_STAGE}/usr/lib/camx/kodiak/camera/"
    done
    for file in "${source_usr}/lib/camx/kodiak/camera"/com.qti.sensor*.so*; do
        copy_library "$file" "${CHICDK_STAGE}/usr/lib/camx/kodiak/camera"
    done

    # Optional command-line tools and package documentation.
    if [[ -d "${source_usr}/bin" ]]; then
        for file in "${source_usr}/bin"/*; do
            [[ -f "$file" ]] || continue
            install -D -m 0755 "$file" "${CHICDK_STAGE}/usr/bin/$(basename "$file")"
        done
        for file in "${source_usr}/bin/camx/kodiak"/*; do
            [[ -f "$file" ]] || continue
            install -D -m 0755 "$file" "${CHICDK_STAGE}/usr/libexec/camx/kodiak/$(basename "$file")"
        done
    fi
    if [[ -d "${source_usr}/share/doc/chicdk-kodiak" ]]; then
        mkdir -p "${CHICDK_STAGE}/usr/share/doc/chicdk-kodiak"
        for file in "${source_usr}/share/doc/chicdk-kodiak"/*; do
            [[ -f "$file" ]] || continue
            install -m 0644 "$file" "${CHICDK_STAGE}/usr/share/doc/chicdk-kodiak/"
        done
    fi
    copy_common_docs "$source_usr" "$CHICDK_STAGE"
}

stage_chicdk_imx577() {
    local source_usr="$1"
    reset_stage "$CHICDK_IMX577_STAGE"

    local source_camera="${CHICDK_STAGE}/usr/lib/camx/kodiak/camera"
    local destination_camera="${CHICDK_IMX577_STAGE}/usr/lib/camx/kodiak/camera"
    mkdir -p "$destination_camera"

    local file
    for file in \
        com.qti.sensor.cmk_imx577.so.0 \
        com.qti.sensor.cmk_imx577.so.0.1.0 \
        com.qti.sensormodule.cmk_imx577_cam1.bin \
        com.qti.sensormodule.cmk_imx577_cam2.bin \
        com.qti.sensormodule.cmk_imx577_cam3.bin \
        com.qti.tuned.kodiak_cmk_imx577.bin; do
        if [[ ! -e "${source_camera}/${file}" && ! -L "${source_camera}/${file}" ]]; then
            echo "ERROR: missing IMX577 package file: ${source_camera}/${file}" >&2
            return 1
        fi
        mv "${source_camera}/${file}" "$destination_camera/"
    done

    copy_common_docs "$source_usr" "$CHICDK_IMX577_STAGE"
}

stage_chicdk_imx415() {
    local source_camera="${CHICDK_STAGE}/usr/lib/camx/kodiak/camera"
    local package_camera="${CHICDK_IMX415_STAGE}/usr/lib/camx/kodiak/camera"

    # The IMX415 package tree is maintained directly in this repository
    # (sensor module bin and tuning bin are swapped by hand), so the staged
    # contents are intentionally not pinned to fixed hashes here.  Only the
    # structural sanity of the staged tree is checked.
    if [[ "$(readlink "${package_camera}/com.qti.sensor.imx415.so.0")" != \
        "com.qti.sensor.imx415.so.0.1.0" ]]; then
        echo "ERROR: invalid IMX415 sensor SONAME symlink" >&2
        return 1
    fi

    rm -f "${source_camera}/com.qti.sensormodule.sony_imx415.bin"
}

main() {
    local camxlib_tmp camx_tmp chicdk_tmp
    local camxlib_root camx_root chicdk_root
    camxlib_tmp="$(mktemp -d "${TMPDIR:-/tmp}/camxlib-kodiak.XXXXXX")"
    camx_tmp="$(mktemp -d "${TMPDIR:-/tmp}/camx-kodiak.XXXXXX")"
    chicdk_tmp="$(mktemp -d "${TMPDIR:-/tmp}/chicdk-kodiak.XXXXXX")"
    trap 'rm -rf "${camxlib_tmp:-}" "${camx_tmp:-}" "${chicdk_tmp:-}"' EXIT

    fetch_archive "$CAMXLIB_ARCHIVE" "$CAMXLIB_SHA256"
    fetch_archive "$CAMX_ARCHIVE" "$CAMX_SHA256"
    fetch_archive "$CHICDK_ARCHIVE" "$CHICDK_SHA256"

    camxlib_root="$(unpack_archive "$CAMXLIB_ARCHIVE" "$camxlib_tmp")"
    camx_root="$(unpack_archive "$CAMX_ARCHIVE" "$camx_tmp")"
    chicdk_root="$(unpack_archive "$CHICDK_ARCHIVE" "$chicdk_tmp")"

    # Qualcomm tarballs ship overlapping files across the three archives.
    # Remove them from the camxlib source so stage_camxlib can use
    # plain globs without ad-hoc exclusions.
    #
    # CamX hardware and format utilities belong to camx-kodiak.
    local camxlib_src="${camxlib_root}/usr/lib/camx/kodiak"
    rm -f "${camxlib_src}"/libcamera_hardware.so* \
          "${camxlib_src}"/libcamxexternalformatutils.so* \
          "${camxlib_src}"/libcamximageformatutils.so*

    stage_camxlib "${camxlib_root}/usr"
    stage_camx "${camx_root}/usr"
    stage_chicdk "${chicdk_root}/usr"
    stage_chicdk_imx577 "${chicdk_root}/usr"
    stage_chicdk_imx415

    # Fix permissions: Qualcomm archives ship with root/root ownership,
    # which breaks fakeroot + cp -a --reflink on NFS/sshfs builds.
    # Make everything readable and directories traversable.
    chmod -R a+rX "$CAMXLIB_STAGE" "$CAMX_STAGE" "$CHICDK_STAGE" \
        "$CHICDK_IMX577_STAGE" "$CHICDK_IMX415_STAGE"

    echo "CamX package staging updated: ${CAMX_VERSION} (${PBT_BUILD_DATE})"
    find "$CAMXLIB_STAGE/usr" "$CAMX_STAGE/usr" "$CHICDK_STAGE/usr" \
        "$CHICDK_IMX577_STAGE/usr" "$CHICDK_IMX415_STAGE/usr" \
        \( -type f -o -type l \) -print | sort
}

main "$@"
