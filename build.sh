#!/bin/bash

# Pastikan submodule LKM_Tools ditarik
git submodule update --init --recursive

export WDIR="$(dirname $(readlink -f $0))" && cd "$WDIR"
export MERGE_CONFIG="${WDIR}/kernel_platform/common/scripts/kconfig/merge_config.sh"

# Deklarasi alat panen dari LKM_Tools
export PKG_VENDOR_BOOT="${WDIR}/LKM_Tools/02.prepare_vendor_boot_modules.sh"
export PKG_VENDOR_DLKM="${WDIR}/LKM_Tools/03.prepare_vendor_dlkm.sh"

clean_up(){
    rm -rf "${WDIR}/dist" \
        && rm -rf "${WDIR}/out" \
        && mkdir -p "${WDIR}/dist"
}

# Download and install Toolchain (DIBUNGKAM AGAR SERVER TIDAK CRASH)
if [ ! -d "${WDIR}/kernel_platform/prebuilts" ]; then
    echo -e "[+] Downloading Toolchain (Silent Mode)...\n"
    sudo apt install rsync p7zip-full -y > /dev/null 2>&1
    curl -LO --progress-bar https://github.com/ravindu644/android_kernel_sm_x810/releases/download/toolchain/qcom-5.15-toolchain.tar.gz.zip
    curl -LO --progress-bar https://github.com/ravindu644/android_kernel_sm_x810/releases/download/toolchain/qcom-5.15-toolchain.tar.gz.z01
    
    echo "[+] Mengekstrak arsip 7z..."
    7z x qcom-5.15-toolchain.tar.gz.zip > /dev/null 2>&1
    rm qcom-5.15-toolchain.tar.gz.zip qcom-5.15-toolchain.tar.gz.z01
    
    echo "[+] Mengekstrak arsip tar (Tunggu sebentar, sedang berjalan tanpa log)..."
    tar -xf qcom-5.15-toolchain.tar.gz
    rm qcom-5.15-toolchain.tar.gz
    
    mv prebuilts "${WDIR}/kernel_platform" && chmod -R +x "${WDIR}/kernel_platform/prebuilts"    
fi

echo -e "[+] Toolchain terpasang dengan aman...\n"

# setup localversion
if [ -z "$BUILD_KERNEL_VERSION" ]; then
    export BUILD_KERNEL_VERSION="KSU-SuSFS"
fi

mkdir -p "${WDIR}/custom_defconfigs"
echo -e "CONFIG_LOCALVERSION_AUTO=n\nCONFIG_LOCALVERSION=\"-dapurandroid-${BUILD_KERNEL_VERSION}\"\n" > "${WDIR}/custom_defconfigs/version_defconfig"

#1. target config
export MODEL="a05s"
export PROJECT_NAME=${MODEL}
export REGION="eur"
export CARRIER="open"
export TARGET_BUILD_VARIANT="user"

#2. sm8550 common config (sm6225 actually)
CHIPSET_NAME="sm6225"

export ANDROID_BUILD_TOP=$(pwd)
export TARGET_PRODUCT=gki
export TARGET_BOARD_PLATFORM=gki

export ANDROID_PRODUCT_OUT=${ANDROID_BUILD_TOP}/out/target/product/${MODEL}
mkdir -p ${ANDROID_PRODUCT_OUT}
export OUT_DIR=${ANDROID_BUILD_TOP}/out/msm-${CHIPSET_NAME}-${CHIPSET_NAME}-${TARGET_PRODUCT}
mkdir -p ${OUT_DIR}

#3. build kernel menggunakan MASTER SAMSUNG
build_kernel(){
    echo -e "[+] Mengeksekusi Koki Master Samsung...\n"
    
    # Biarkan LTO default (Full) bekerja, mesin Vultr kita kuat
    export MAKEFLAGS="-j$(nproc)"
    
    chmod +x build_kernel_GKI.sh
    UPDATE_KMI_SYMBOL_LIST=1 SKIP_DEFCONFIG_CHECK=1 IGNORE_DEFCONFIG_ERRORS=1 LTO=thin ./build_kernel_GKI.sh a05s_global_gki userdebug sm6225 || exit 1
}

#4. copy kernel image to dist directory
copy_stuff(){
    if [ -f "${OUT_DIR}/dist/Image" ]; then
        cp "${OUT_DIR}/dist/Image" "${WDIR}/dist/Image"
    else
        echo -e "[-] Error: Image not found\n"
        exit 1
    fi
}

#5. Convert modules.dep to modules_list.txt
convert_module_lists(){
    echo -e "[+] Menerjemahkan modules.dep bawaan pabrik...\n"
    ${WDIR}/LKM_Tools/01.module_dep.sh ${WDIR}/prebuilts_a05s/vendor_boot/modules.dep ${WDIR}/prebuilts_a05s/vendor_boot
    ${WDIR}/LKM_Tools/01.module_dep.sh ${WDIR}/prebuilts_a05s/vendor_dlkm/modules.dep ${WDIR}/prebuilts_a05s/vendor_dlkm
}

#6. Package vendor_boot modules
package_vendor_boot_modules(){
    mkdir -p ${WDIR}/dist/built_vendor_boot_modules
    echo -e "[+] Packaging vendor_boot modules...\n"

    ${PKG_VENDOR_BOOT} \
        ${WDIR}/prebuilts_a05s/vendor_boot/modules_list.txt \
        ${OUT_DIR}/staging \
        ${WDIR}/prebuilts_a05s/vendor_boot/modules.load \
        ${OUT_DIR}/dist/System.map \
        ${WDIR}/kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/bin/llvm-strip \
        ${WDIR}/dist/built_vendor_boot_modules
}

#7. Package vendor_dlkm modules (Full System Drivers)
package_vendor_dlkm_modules(){
    mkdir -p ${WDIR}/dist/built_vendor_dlkm_modules
    echo -e "[+] Packaging vendor_dlkm modules (Applying sec.ko blacklist)...\n"

    ${PKG_VENDOR_DLKM} \
        ${WDIR}/prebuilts_a05s/vendor_dlkm/modules_list.txt \
        ${OUT_DIR}/staging \
        ${WDIR}/prebuilts_a05s/vendor_dlkm/modules.load \
        ${OUT_DIR}/dist/System.map \
        ${WDIR}/kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/bin/llvm-strip \
        ${WDIR}/dist/built_vendor_dlkm_modules \
        ${WDIR}/prebuilts_a05s/vendor_boot/modules_list.txt \
        "" \
        ${WDIR}/prebuilts_a05s/vendor_dlkm/modules.blacklist
}

zip_dist_files(){
    echo -e "[+] Zipping dist files...\n"
    cd "${WDIR}/dist" && zip -r -9 "${WDIR}/Kernel_A05s_KSU_SuSFS_Full.zip" Image built_vendor_boot_modules built_vendor_dlkm_modules && cd "${WDIR}"
}

clean_up
build_kernel
copy_stuff
convert_module_lists
package_vendor_boot_modules
package_vendor_dlkm_modules
zip_dist_files

echo -e "[+] Kernel build completed successfully\n"
