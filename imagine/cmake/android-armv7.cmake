include("${CMAKE_CURRENT_LIST_DIR}/android-config.cmake")

set(CMAKE_SYSTEM_PROCESSOR armv7-a)
set(CMAKE_ANDROID_ARCH_ABI armeabi-v7a)
set(ARCH arm)
set(SUBARCH armv7)
set(CTARGET arm-linux-androideabi)
# Must declare min API 21 to compile with NDK r26+ headers
set(ANDROID_CTARGET armv7-none-linux-androideabi21)
set(ANDROID_NDK_SDK 9)
set(CFLAGS_CODEGEN "-march=armv7-a -mthumb -mtune=cortex-a9 -mfpu=neon -mfloat-abi=softfp")
set(LDFLAGS "-Wl,--fix-cortex-a8")
set(LIBCXX_SUPPORT_LIBS "-landroid_support")
set(CMAKE_ASM_FLAGS_INIT "-Wa,--noexecstack,-EL -march=armv7-a")

# Call the GNU assembler via GCC until assembly in projects is updated for clang's integrated assembler

find_program(gnuAs arm-none-linux-gnueabi-gcc)
if(NOT gnuAs)
	find_program(gnuAs arm-linux-gnueabi-gcc)
endif()
set(CMAKE_ASM_COMPILER "${gnuAs}")

include("${CMAKE_CURRENT_LIST_DIR}/android.cmake")
