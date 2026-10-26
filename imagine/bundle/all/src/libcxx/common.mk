libcxxVersion := 22.1.0
llvmSrcDir := $(tempDir)/llvm-project-$(libcxxVersion).src
libcxxSrcDir := $(llvmSrcDir)/libcxx
libcxxabiSrcDir := $(llvmSrcDir)/libcxxabi
libcSrcDir := $(llvmSrcDir)/libc
# Archive containing the libcxx & libcxxabi directories along with a minimal set of cmake support files
libcxxSrcArchive := llvm-project-libcxx-$(libcxxVersion).src.tar.xz

makeFile := $(buildDir)/Makefile
outputLibFile := $(buildDir)/lib/libc++.a
outputLibcxxabiFile := $(buildDir)/lib/libc++abi.a
installIncludeDir := $(installDir)/include/c++/v1
installModulesSrcDir := $(installDir)/share/libc++/v1

# Extract libc++ before setting VPATH
ifeq ($(wildcard $(libcxxabiSrcDir)/src),)
 $(info Extracting libc++...)
 $(shell mkdir -p $(tempDir))
 $(shell tar -mxJf $(libcxxSrcArchive) -C $(tempDir))
 $(shell patch -s -d $(llvmSrcDir) -p1 -i $(CURDIR)/unwind.patch)
 $(if $(filter-out 0,$(.SHELLSTATUS)), $(error patch failed with exit status $(.SHELLSTATUS)))
endif

VPATH += $(libcxxabiSrcDir)/src
CXXABI_SRC := abort_message.cpp \
 cxa_aux_runtime.cpp \
 cxa_default_handlers.cpp \
 cxa_demangle.cpp \
 cxa_exception.cpp \
 cxa_exception_storage.cpp \
 cxa_guard.cpp \
 cxa_handlers.cpp \
 cxa_personality.cpp \
 cxa_thread_atexit.cpp \
 cxa_vector.cpp \
 cxa_virtual.cpp \
 fallback_malloc.cpp \
 private_typeinfo.cpp \
 stdlib_exception.cpp \
 stdlib_new_delete.cpp \
 stdlib_stdexcept.cpp \
 stdlib_typeinfo.cpp
CXXABI_OBJ := $(addprefix $(objDir)/,$(CXXABI_SRC:.cpp=.o))

all : $(outputLibFile) $(outputLibcxxabiFile)

install : $(outputLibFile) $(outputLibcxxabiFile)
	@echo "Installing libc++ to: $(installDir)"
	@mkdir -p $(installIncludeDir) $(installModulesSrcDir) $(installDir)/lib
	cp $(outputLibFile) $(outputLibcxxabiFile) $(buildDir)/lib/libc++experimental.a $(buildDir)/lib/libc++.modules.json $(installDir)/lib/
	cp -r $(buildDir)/include/c++/v1/* $(installIncludeDir)/
	cp -r $(buildDir)/modules/c++/v1/* $(installModulesSrcDir)/
	cp -r $(libcxxabiSrcDir)/include/* $(installIncludeDir)/
	cp -r std/* $(installModulesSrcDir)/std/
	cp -r std.compat/* $(installModulesSrcDir)/std.compat/

.PHONY : all install

# build libc++abi after libc++ and use its build headers
$(CXXABI_OBJ) : | $(outputLibFile)
$(CXXABI_OBJ) : CPPFLAGS += -DHAVE___CXA_THREAD_ATEXIT_IMPL -D_LIBCPP_DISABLE_EXTERN_TEMPLATE -D_LIBCPP_BUILDING_LIBRARY -D_LIBCXXABI_BUILDING_LIBRARY -I$(libcxxSrcDir)/src -I$(buildDir)/include/c++/v1

CPPFLAGS += -nostdinc++ -I$(libcxxabiSrcDir)/include -I$(libcSrcDir) -Wno-user-defined-literals -U_LIBCPP_LINK_PTHREAD_LIB -U_LIBCPP_LINK_RT_LIB

$(outputLibcxxabiFile) : $(CXXABI_OBJ)
	@echo "Archiving libc++abi..."
	@mkdir -p `dirname $@`
	$(AR) rcs $@ $^

$(outputLibFile) : $(makeFile)
	@echo "Building libc++..."
	$(MAKE) -j4 -C $(<D)

$(makeFile) : $(libcxxSrcDir)/CMakeLists.txt
	@echo "Configuring libc++..."
	@mkdir -p $(@D)
	dir=`pwd` && cd $(libcxxSrcDir) && $(toolchainEnvParams) cmake -DLIBCXX_ENABLE_SHARED=OFF \
	-DLIBCXX_CXX_ABI=libcxxabi -DLLVM_INCLUDE_TESTS=OFF -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF \
	-DLIBCXX_ENABLE_DEBUG_MODE_SUPPORT=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="$(CPPFLAGS) $(CXXFLAGS)" \
	-DLIBCXX_ABI_UNSTABLE=ON -DLIBCXX_ENABLE_INCOMPLETE_FEATURES=ON -DCMAKE_CXX_COMPILER_TARGET=$(clangTarget) \
	-DLIBCXX_HERMETIC_STATIC_LIBRARY=ON -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_ENABLE_TIME_ZONE_DATABASE=OFF \
	$(buildArg) -B $(@D)
