# common utility functions and variable setup included by all toolchain files

function(setFromEnv var defaultVal)
	set(envValue "$ENV{${var}}")
	if(NOT envValue)
		set(${var} "${defaultVal}" PARENT_SCOPE)
	else()
		set(${var} "${envValue}" PARENT_SCOPE)
	endif()
endFunction()

function(getProp out target prop)
	get_target_property(v ${target} ${prop})
	if(NOT v)
		set(${out} "" PARENT_SCOPE)
		return()
	endif()
	set(${out} "${v}" PARENT_SCOPE)
endFunction()

function(getJoinedProp out target prop)
	getProp(v ${target} ${prop})
	list(JOIN v " " v)
	set(${out} "${v}" PARENT_SCOPE)
endFunction()

function(printConfigInfo)
	message("C Flags (Common): ${CMAKE_C_FLAGS}")
	message("C Flags (Debug): ${CMAKE_C_FLAGS_DEBUG}")
	message("C Flags (Release): ${CMAKE_C_FLAGS_RELEASE}")
	message("C Flags (Release + Debug Info): ${CMAKE_C_FLAGS_RELWITHDEBINFO}")
	message("C++ Flags (Common): ${CMAKE_CXX_FLAGS}")
	message("C++ Flags (Debug): ${CMAKE_CXX_FLAGS_DEBUG}")
	message("C++ Flags (Release): ${CMAKE_CXX_FLAGS_RELEASE}")
	message("C++ Flags (Release + Debug Info): ${CMAKE_CXX_FLAGS_RELWITHDEBINFO}")
	if(CMAKE_ASM_COMPILER_LOADED)
		message("ASM Flags (Common): ${CMAKE_ASM_FLAGS}")
	endif()
	message("Linker Flags (Common): ${CMAKE_EXE_LINKER_FLAGS}")
	message("Linker Flags (Debug): ${CMAKE_EXE_LINKER_FLAGS_DEBUG}")
	message("Linker Flags (Release): ${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
	message("Linker Flags (Release + Debug Info): ${CMAKE_EXE_LINKER_FLAGS_RELWITHDEBINFO}")
	message("SDK Path: ${IMAGINE_SDK_PLATFORM_PATH}")
endFunction()

# config.h generation

function(addConfigEnable target v)
	set_property(TARGET ${target} APPEND PROPERTY configEnable "${v}")
endFunction()

function(generateConfigHeader target)
	getJoinedProp(configEnable ${target} configEnable)
	getJoinedProp(configDisable ${target} configDisable)
	getJoinedProp(configInc ${target} configInc)
	set(configDefs "IMAGINE_VERSION_BASE=\"${PROJECT_VERSION}\"")
	set(configFilename "${target}-config.h")
	set(genDir "${CMAKE_BINARY_DIR}/gen")
	set(configFilePath "${genDir}/${configFilename}")
	message("Config Header: ${configFilePath}")
	execute_process(
		COMMAND mkdir -p ${genDir}
		COMMAND bash ${IMAGINE_PATH}/make/writeConfig.sh "${configFilePath}" "${configEnable}" "${configDisable}" "${configInc}" "${configDefs}"
		COMMAND_ERROR_IS_FATAL ANY
	)	
	target_include_directories(${target} PRIVATE ${genDir})
	install(FILES "${configFilePath}" DESTINATION include)
endFunction()

# pkg-config support

function(addPkgConfigDeps target dep)
	set_property(TARGET ${target} APPEND PROPERTY PKG_CONFIG_TARGET_DEPS "${dep}")
endFunction()

function(addPkgConfigDepsForConfig target dep config)
	set_property(TARGET ${target} APPEND PROPERTY PKG_CONFIG_TARGET_DEPS_${config} "${dep}")
endFunction()

function(addPkgConfigDepMultiConfig target dep)
	foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
		addPkgConfigDepsForConfig(${target} ${dep}${TARGET_EXT_${config}} ${config})
	endforeach()
endFunction()

function(addPkgConfigLibs target lib)
	set_property(TARGET ${target} APPEND PROPERTY PKG_CONFIG_TARGET_LIBS "${lib}")
endFunction()

function(evalPkgConfigFlags target mode)
	getJoinedProp(pkgConfigDeps ${target} PKG_CONFIG_TARGET_DEPS)
	foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
		getJoinedProp(pkgConfigDeps${config} ${target} PKG_CONFIG_TARGET_DEPS_${config})
	endforeach()
	set(pkgConfigDepsAll "${pkgConfigDeps}")
	string(APPEND pkgConfigDepsAll " ${pkgConfigDepsRelease}")

	if(pkgConfigDepsAll)
		message("Config Packages: ${pkgConfigDepsAll}")
	else()
		message("No config packages")
		return()
	endif()

	set(ENV{PKG_CONFIG_PATH} "${PKG_CONFIG_PATH}")
	set(ENV{PKG_CONFIG_SYSTEM_INCLUDE_PATH} "${PKG_CONFIG_SYSTEM_INCLUDE_PATH}")
	set(ENV{PKG_CONFIG_SYSTEM_LIBRARY_PATH} "${PKG_CONFIG_SYSTEM_LIBRARY_PATH}")

	if(mode STREQUAL all OR mode STREQUAL cflags)
		execute_process(
			COMMAND pkg-config --cflags ${pkgConfigOpts} ${pkgConfigDeps} ${pkgConfigDepsRelease}
			OUTPUT_VARIABLE pkgConfigCFlagsOutput
			OUTPUT_STRIP_TRAILING_WHITESPACE
			COMMAND_ERROR_IS_FATAL ANY
		)
		message("Package Flags: ${pkgConfigCFlagsOutput}")
		string(REPLACE " " ";" pkgConfigCFlagsOutput "${pkgConfigCFlagsOutput}")
		target_compile_options(${target} PRIVATE ${pkgConfigCFlagsOutput})
	endif()

	if(mode STREQUAL all OR mode STREQUAL libs)
		foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
			execute_process(
				COMMAND pkg-config --libs ${pkgConfigOpts} ${pkgConfigDeps} ${pkgConfigDeps${config}}
				OUTPUT_VARIABLE pkgConfigLibsOutput
				OUTPUT_STRIP_TRAILING_WHITESPACE
				RESULT_VARIABLE resultCode
			)
			if(resultCode)
				message("Package Libs (${config}): not configured")
			else()
				message("Package Libs (${config}): ${pkgConfigLibsOutput}")
				string(REPLACE " " ";" pkgConfigLibsOutput "${pkgConfigLibsOutput}")
				if(ENV STREQUAL ios)
					list(TRANSFORM pkgConfigLibsOutput PREPEND "SHELL:")
					string(REPLACE "=" " " pkgConfigLibsOutput "${pkgConfigLibsOutput}")
					target_link_options(${target} PRIVATE $<$<CONFIG:${config}>:${pkgConfigLibsOutput}>)
				else()
					target_link_libraries(${target} PRIVATE $<$<CONFIG:${config}>:${pkgConfigLibsOutput}>)
				endif()
			endif()
		endforeach()
	endif()
endFunction()

function(evalPkgConfigCFlags target)
	evalPkgConfigFlags(${target} cflags)
endFunction()

function(writePkgConfigFiles target)
	getJoinedProp(pkgRequires ${target} PKG_CONFIG_TARGET_DEPS)
	getJoinedProp(pkgLibs ${target} PKG_CONFIG_TARGET_LIBS)	
	foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
		set(targetExt "${TARGET_EXT_${config}}")
		getJoinedProp(pkgRequiresForConfig ${target} PKG_CONFIG_TARGET_DEPS_${config})
		set(PKG_CONFIG_REQUIRES "${pkgRequires} ${pkgRequiresForConfig}")
		set(PKG_CONFIG_LIBS "-l${target}${targetExt} ${pkgLibs}")
		configure_file(
			"${IMAGINE_PATH}/cmake/pkgconfig.pc.in"
			"${CMAKE_BINARY_DIR}/${target}${targetExt}.pc"
			@ONLY
		)
	endforeach()
	# directly copy the .pc file else ${pcfiledir} will incorrectly point to the build directory when using CMAKE_INSTALL_MODE with symlinks
	install(CODE "
		file(COPY \"${CMAKE_BINARY_DIR}/${target}${GEN_TARGET_EXT}.pc\" DESTINATION \"${CMAKE_INSTALL_PREFIX}/lib/pkgconfig/\")
	")
endFunction()

function(addPkgAlsa target)
	addConfigEnable(${target} CONFIG_PACKAGE_ALSA)
	addPkgConfigDeps(${target} alsa)
endFunction()

function(addPkgBluez target)
	if(NOT ENV STREQUAL android)
		addPkgConfigDeps(${target} bluez)
	endif()
endFunction()

function(addPkgBtStack target)
	addPkgConfigLibs(${target} -lBTstack)
endFunction()

function(addPkgEgl target)
	if(ENV STREQUAL android OR SUBENV STREQUAL pandora)
		addPkgConfigLibs(${target} -lEGL)
	elseif(ENV STREQUAL linux)
		addPkgConfigDeps(${target} egl)
	endif()
endfunction()

function(addPkgFlac target)
	addPkgConfigDeps(${target} flac)
	addPkgConfigDeps(${target} ogg)
endFunction()

function(addPkgFontconfig target)
	addConfigEnable(${target} CONFIG_PACKAGE_FONTCONFIG)
	addPkgConfigDeps(${target} fontconfig)
endFunction()

function(addPkgFreetype target)
	addPkgConfigDeps(${target} freetype2)
endFunction()

function(addPkgGio target)
	addConfigEnable(${target} CONFIG_PACKAGE_DBUS)
	addPkgConfigDeps(${target} gio-2.0)
endFunction()

function(addPkgGlib target)
	addPkgConfigDeps(${target} glib-2.0)
endFunction()

function(addPkgZlib target)
	set(envWithLib android;ios)
	if(ENV IN_LIST envWithLib)
		addPkgConfigLibs(${target} -lz)
	else()
		addPkgConfigDeps(${target} zlib)
	endif()
endFunction()

function(addPkgLibarchive target)
	addPkgZlib(${target})
	if(ENV STREQUAL linux)
		addPkgConfigDeps(${target} "liblzma")
		addPkgConfigLibs(${target} "${IMAGINE_SDK_PLATFORM_PATH}/lib/libarchive.a")
	else()
		addPkgConfigDeps(${target} "libarchive liblzma")
	endif()
endFunction()

function(addPkgLibdrm target)
	addConfigEnable(${target} CONFIG_PACKAGE_LIBDRM)
	addPkgConfigDeps(${target} libdrm)
endFunction()

function(addPkgLibpng target)
	addPkgConfigDeps(${target} libpng)
endFunction()

function(addPkgLibvorbis target)
	addConfigEnable(${target} CONFIG_PACKAGE_LIBVORBIS)
	addPkgConfigDeps(${target} vorbisfile)
	addPkgConfigDeps(${target} vorbis)
	addPkgConfigDeps(${target} ogg)
endFunction()

function(addPkgOpenGL target)
	if(SUBENV STREQUAL pandora)
		addPkgConfigLibs(${target} "-lGLESv2 -lm")
	elseif(ENV STREQUAL linux)
		if(OPENGL_API STREQUAL gles)
			addPkgConfigDeps(${target} glesv2)
		else()
			addPkgConfigDeps(${target} gl)
		endif()
	elseif(ENV STREQUAL android)
		addPkgConfigLibs(${target} -lGLESv2)
	elseif(ENV STREQUAL ios)
		addPkgConfigLibs(${target} "-framework=OpenGLES")
	elseif(ENV STREQUAL macosx)
		addPkgConfigLibs(${target} "-framework=OpenGL" "-framework=CoreVideo")
	endif()
endFunction()

function(addPkgPulseAudio target)
	addConfigEnable(${target} CONFIG_PACKAGE_PULSEAUDIO)
	addPkgConfigDeps(${target} libpulse)
endfunction()

function(addPkgX11 target)
	addConfigEnable(${target} CONFIG_PACKAGE_X11)
	addPkgConfigDeps(${target} "xcb xcb-xfixes xcb-xinput xcb-icccm xkbcommon xkbcommon-x11")
endfunction()

function(addPkgXRandr target)
	addPkgConfigDeps(${target} xcb-randr)
endfunction()

# app target support

function(setAllVarsFromFile filePath)
	file(STRINGS "${filePath}" fileLines)
	foreach(line IN LISTS fileLines)
	string(FIND "${line}" "=" equalPos)
		if(equalPos GREATER -1)
			math(EXPR varNameLen "${equalPos}")
			string(SUBSTRING "${line}" 0 "${varNameLen}" varName)
			math(EXPR valueStart "${equalPos} + 1")
			string(SUBSTRING "${line}" "${valueStart}" -1 value)
			string(STRIP "${varName}" varName)
			string(STRIP "${value}" value)
			set(${varName} "${value}" PARENT_SCOPE)
			#message(STATUS "Read variable ${varName} = ${value}")
		endif()
	endforeach()
endfunction()

function(configureAppTarget target)
	setAllVarsFromFile(metadata/conf.mk)
	set(configFilename "meta.h")
	set(genDir "${CMAKE_BINARY_DIR}/gen")
	set(configFilePath "${genDir}/${configFilename}")
	message("Metadata Header: ${configFilePath}")
	if(ENV STREQUAL android AND android_metadata_id)
		set(metadata_id ${android_metadata_id})
	endif()
	if(NOT metadata_name)
		message(FATAL_ERROR "metadata_name not defined in metadata/conf.mk")
	endif()
	if(NOT metadata_id)
		message(FATAL_ERROR "metadata_id not defined in metadata/conf.mk")
	endif()
	file(WRITE ${configFilePath}
		"#pragma once\n"
		"#define CONFIG_APP_NAME \"${metadata_name}\"\n"
		"#define CONFIG_APP_ID \"${metadata_id}\"\n"
	)
	if(ENV STREQUAL android)
		add_library(${target} SHARED ${ARGN})
		set_target_properties(${target} PROPERTIES OUTPUT_NAME "main")
		set(libOutputDir "${CMAKE_BINARY_DIR}/../android${GEN_TARGET_EXT}/src/main/jniLibs/${CMAKE_ANDROID_ARCH_ABI}")
		set(LIBRARY_OUTPUT_DIR ${libOutputDir} PARENT_SCOPE)
		set_target_properties(${target} PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${libOutputDir})
		file(WRITE "${CMAKE_BINARY_DIR}/${target}_debug_retainedSymbols.txt" "ANativeActivity_onCreate\n")
		file(WRITE "${CMAKE_BINARY_DIR}/${target}_release_retainedSymbols.txt" "ANativeActivity_onCreate\n")
		target_link_options(${target} PRIVATE
			"-Wl,--no-undefined,--retain-symbols-file=${CMAKE_BINARY_DIR}/${target}_$<$<CONFIG:Debug>:debug>$<$<NOT:$<CONFIG:Debug>>:release>_retainedSymbols.txt")
		if(ENV{ANDROID_GOOGLE_PLAY_STORE_BUILD})
			file(APPEND ${configFilePath} "#define CONFIG_GOOGLE_PLAY_STORE\n")
		endif()
	else()
		add_executable(${target} ${ARGN})
		if(ENV STREQUAL linux)
			set(LIBRARY_OUTPUT_DIR "${CMAKE_BINARY_DIR}/../linux${GEN_TARGET_EXT}" PARENT_SCOPE)
			set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY
				"${CMAKE_BINARY_DIR}/../linux${GEN_TARGET_EXT}")
		elseif(ENV STREQUAL ios)
			add_custom_command(
				TARGET ${target}
				POST_BUILD
				COMMAND ldid -S $<TARGET_FILE:${target}>
				COMMENT "Signing executable"
			)
		elseif(SUBENV STREQUAL pandora)
			set(LIBRARY_OUTPUT_DIR "${CMAKE_BINARY_DIR}/../pandora${GEN_TARGET_EXT}/${metadata_pkgName}" PARENT_SCOPE)
			set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY
				"${CMAKE_BINARY_DIR}/../pandora${GEN_TARGET_EXT}/${metadata_pkgName}")
		endif()
	endif()
	target_include_directories(${target} PRIVATE ${genDir} ${PROJECT_SOURCE_DIR}/src)
	target_link_options(${target} PRIVATE ${CXX_STD_LINK_OPTS})
	target_link_libraries(${target} PRIVATE ${CXX_STD_LINK_LIBS})
	set_target_properties(${target} PROPERTIES CXX_MODULE_STD ON)
endfunction()

function(configureAppLibraryTarget target)
	add_library(${target} SHARED ${ARGN})
	target_link_options(${target} PRIVATE ${CXX_STD_LINK_OPTS})
	if(LIBRARY_OUTPUT_DIR)
		set_target_properties(${target} PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${LIBRARY_OUTPUT_DIR})
	endif()
endfunction()

function(setExportedSymbols target config)
	if(ENV STREQUAL linux)
		target_link_options(${target} PRIVATE -Wl,--export-dynamic)
	elseif(ENV STREQUAL android)
		foreach(arg IN LISTS ARGN)
			file(APPEND "${CMAKE_BINARY_DIR}/${target}_${config}_retainedSymbols.txt" "${arg}\n")
		endforeach()
	endif()
endfunction()

# C++ modules

function(addCxxModules target mainModule)
	set(moduleDir "${IMAGINE_SDK_PLATFORM_PATH}/share/modules")
	target_sources(${target} PRIVATE FILE_SET CXX_MODULES BASE_DIRS ${moduleDir} FILES "${moduleDir}/${mainModule}.ccm")
	foreach(extraModule ${ARGN})
		target_sources(${target} PRIVATE FILE_SET CXX_MODULES BASE_DIRS ${moduleDir} FILES "${moduleDir}/${extraModule}.ccm")
	endforeach()
endfunction()

# set imagine path

set(IMAGINE_PATH "$ENV{IMAGINE_PATH}")
setFromEnv(IMAGINE_SDK_PATH "$ENV{HOME}/imagine-sdk")

if(NOT IS_DIRECTORY "${IMAGINE_PATH}/cmake")
	message(FATAL_ERROR "Invalid Imagine path:${IMAGINE_PATH}, please set IMAGINE_PATH to the root path of the Imagine distribution")
endif()

# init toolchain variables

set(CFLAGS)
set(CXXFLAGS)
set(CFLAGS_COMMON) # common C/C++ flags that don't affect generated code
set(CFLAGS_COMMON_RELEASE)
set(CFLAGS_CODEGEN) # common C/C++ flags that do affect generated code
set(OBJCFLAGS)
set(LDFLAGS)
set(LDFLAGS_STRIP)
set(LDFLAGS_SHARED)
set(TARGET_EXT_Debug -debug)
set(TARGET_EXT_RelWithDebInfo -rdebug)
set(GEN_TARGET_EXT)
set(CMAKE_EXPERIMENTAL_CXX_IMPORT_STD "f35a9ac6-8463-4d38-8eec-5d6008153e7d")

foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
	string(APPEND GEN_TARGET_EXT "$<$<CONFIG:${config}>:${TARGET_EXT_${config}}>")
endforeach()
