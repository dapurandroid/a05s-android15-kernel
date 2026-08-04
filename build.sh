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

# Download and install Toolchain
if [ ! -d "${WDIR}/kernel_platform/prebuilts" ]; then
    echo -e "[+] Downloading and installing Toolchain...\n"
    sudo apt install rsync p7zip-full -y
    curl -LO --progress-bar https://github.com/ravindu644/android_kernel_sm_x810/releases/download/toolchain/qcom-5.15-toolchain.tar.gz.zip
    curl -LO --progress-bar https://github.com/ravindu644/android_kernel_sm_x810/releases/download/toolchain/qcom-5.15-toolchain.tar.gz.z01
    7z x qcom-5.15-toolchain.tar.gz.zip && rm qcom-5.15-toolchain.tar.gz.zip qcom-5.15-toolchain.tar.gz.z01
    tar -xvf qcom-5.15-toolchain.tar.gz && rm qcom-5.15-toolchain.tar.gz
    mv prebuilts "${WDIR}/kernel_platform" && chmod -R +x "${WDIR}/kernel_platform/prebuilts"    
fi

echo -e "[+] Toolchain installed...\n"

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

# for Lcd(techpack) driver build
export KBUILD_EXTRA_SYMBOLS="${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/mmrm-driver/Module.symvers \
		${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/mm-drivers/hw_fence/Module.symvers \
		${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/mm-drivers/sync_fence/Module.symvers \
		${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/mm-drivers/msm_ext_display/Module.symvers \
		${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/securemsm-kernel/Module.symvers \
"

# for Audio(techpack) driver build
export MODNAME=audio_dlkm

export EXT_MODULES="../vendor/qcom/opensource/mm-drivers/msm_ext_display \
  ../vendor/qcom/opensource/mm-drivers/sync_fence \
  ../vendor/qcom/opensource/mm-drivers/hw_fence \
  ../vendor/qcom/opensource/mmrm-driver \
  ../vendor/qcom/opensource/securemsm-kernel \
  ../vendor/qcom/opensource/display-drivers/msm \
  ../vendor/qcom/opensource/audio-kernel \
  ../vendor/qcom/opensource/camera-kernel \
  ../vendor/qcom/opensource/touch-drivers \
"

export MAKE_MENUCONFIG=0
HERMETIC_VALUE=1
if [ "$MAKE_MENUCONFIG" = "1" ]; then
    HERMETIC_VALUE=0
fi

# custom build options
export GKI_BUILDSCRIPT="./kernel_platform/build/android/prepare_vendor.sh"
export BUILD_OPTIONS=(
    RECOMPILE_KERNEL=1
    SKIP_MRPROPER=0
    HERMETIC_TOOLCHAIN=$HERMETIC_VALUE
    KMI_SYMBOL_LIST_STRICT_MODE=0
    ABI_DEFINITION=""
    LTO="thin"
)

# Kunci Anti-OOM RAM
export MAKEFLAGS="-j3"

#3. build kernel
build_kernel(){
    env ${BUILD_OPTIONS[@]} "${GKI_BUILDSCRIPT}" sec ${TARGET_PRODUCT} || exit 1
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
    cd "${WDIR}/dist" && zip -r -9 "${WDIR}/dist/Kernel_A05s_KSU_SuSFS_Full.zip" Image built_vendor_boot_modules built_vendor_dlkm_modules && cd "${WDIR}"
}

clean_up
build_kernel
copy_stuff
convert_module_lists
package_vendor_boot_modules
package_vendor_dlkm_modules
zip_dist_files

echo -e "[+] Kernel build completed successfully\n"
