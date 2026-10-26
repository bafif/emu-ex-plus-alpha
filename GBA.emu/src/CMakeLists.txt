target_sources(gbaemu PRIVATE FILE_SET CXX_MODULES
	BASE_DIRS main
	FILES main/system.ccm
)

target_sources(gbaemu PRIVATE
	main/Main.cc
	main/AppMeta.cc
	main/options.cc
	main/input.cc
	main/EmuMenuViews.cc
	main/VbamApi.cc
	main/Cheats.cc
	core/gba/gbaCpuThumb.cpp
	core/gba/internal/gbaBios.cpp
	core/gba/gbaCheats.cpp
	core/gba/gbaMode0.cpp
	core/gba/gbaMode1.cpp
	core/gba/gbaMode2.cpp
	core/gba/gbaMode3.cpp
	core/gba/gbaMode4.cpp
	core/gba/gbaMode5.cpp
	core/gba/gbaEeprom.cpp
	core/gba/gbaFlash.cpp
	core/gba/gbaCpuArm.cpp
	core/gba/gba.cpp
	core/gba/gbaRtc.cpp
	core/gba/gbaSound.cpp
	core/gba/internal/gbaSram.cpp
	core/base/patch.cpp
	core/apu/Gb_Apu.cpp
	core/apu/Gb_Oscs.cpp
	core/apu/Blip_Buffer.cpp
	core/apu/Multi_Buffer.cpp
	core/apu/Gb_Apu_State.cpp
)

set_source_files_properties(
	core/gba/gbaCpuArm.cpp
	core/gba/gbaCpuThumb.cpp
	PROPERTIES COMPILE_OPTIONS "-Os"
)