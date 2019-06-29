option(NATIVE          "Compile natively for this CPU" OFF)
option(MINIMAL         "Compile small executable" OFF)
option(EASTL           "Compile with EASTL C++ library" OFF)
option(LTO_ENABLE      "Enable LTO (Clang-only)" OFF)
option(STACK_PROTECTOR "Enable stack protector (SSP)" ON)
option(UBSAN           "Enable the undefined sanitizer" OFF)
option(STRIPPED        "Strip the executable" OFF)
option(DEBUG           "Build and preserve debugging information" OFF)
option(RTTI_EXCEPTIONS "Enable C++ RTTI and exceptions" OFF)
set(CPP_VERSION "c++17" CACHE STRING "C++ version compiler argument")
set(C_VERSION   "gnu11" CACHE STRING "C version compiler argument")
set(LINKER_EXE  "ld"    CACHE STRING "Linker to use")

set(BBPATH ${CMAKE_CURRENT_LIST_DIR})

enable_language(ASM_NASM)
set(ELF_FORMAT "x86_64")
set(CMAKE_ASM_NASM_OBJECT_FORMAT "elf64")
set(OBJCOPY_TARGET "elf64-x86-64")
set(TARGET_TRIPLE  "x86_64-pc-linux")
set(CAPABS "-Wall -Wextra -g -m64 -ffreestanding -fno-omit-frame-pointer -fPIE")

# Optimization flags
set(OPTIMIZE "-mfpmath=sse -msse3")
if (NATIVE)
	set(OPTIMIZE "${OPTIMIZE} -Ofast -march=native")
elseif (MINIMAL)
	if ("${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
		set(OPTIMIZE "${OPTIMIZE} -Oz")
	else()
		set(OPTIMIZE "${OPTIMIZE} -Os")
	endif()
endif()

set(CMAKE_CXX_FLAGS "-MMD ${CAPABS} ${OPTIMIZE} -std=${CPP_VERSION}")
set(CMAKE_C_FLAGS "-MMD ${CAPABS} ${OPTIMIZE} -std=${C_VERSION}")
if (LTO_ENABLE)
	if ("${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
		set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -flto=thin")
		set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -flto=thin")
	else()
		set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -flto")
		set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -flto")
	endif()
	# BUG: workaround for LTO bug
	set(KERNEL_LIBRARY --whole-archive kernel --no-whole-archive)
else()
	set(KERNEL_LIBRARY kernel)
endif()

if (NOT RTTI_EXCEPTIONS)
	set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-exceptions -fno-rtti")
endif()
if ("${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
	set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -target ${TARGET_TRIPLE}")
	set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -target ${TARGET_TRIPLE}")
endif()

# Sanitizer options
if (UBSAN)
	set(UBSAN_PARAMS "-fsanitize=undefined -fno-sanitize=vptr -DUBSAN_ENABLED")
	set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${UBSAN_PARAMS}")
	set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${UBSAN_PARAMS}")
	if ("${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
		set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-sanitize=function")
		set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fno-sanitize=function")
	endif()
endif()
if (STACK_PROTECTOR)
	set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fstack-protector-strong")
	set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fstack-protector-strong")
endif()

# linker stuff
set(CMAKE_LINKER ${LINKER_EXE})
set(CMAKE_SHARED_LIBRARY_LINK_CXX_FLAGS) # this removed -rdynamic from linker output
set(BUILD_SHARED_LIBRARIES OFF)
set(CMAKE_CXX_LINK_EXECUTABLE "<CMAKE_LINKER> -o <TARGET> <LINK_FLAGS> <OBJECTS> <LINK_LIBRARIES>")

string(RANDOM LENGTH 16 ALPHABET 0123456789abcdef SSP_VALUE)
# Add --eh-frame-hdr for exception tables
set(LDSCRIPT "${BBPATH}/src/linker.ld")
set(LDFLAGS "-static -nostdlib -N -melf_${ELF_FORMAT} --script=${LDSCRIPT} --defsym __SSP__=0x${SSP_VALUE}")
if (NOT DEBUG AND STRIPPED)
	set(LDFLAGS "${LDFLAGS} -s")
elseif (NOT DEBUG)
	set(LDFLAGS "${LDFLAGS} -S")
endif()

# Compiler, C and C++ libraries
include(ExternalProject)
ExternalProject_Add(exceptions
			PREFIX exceptions
			URL https://github.com/fwsGonzo/barebones/releases/download/exceptions/exceptions.zip
			URL_HASH SHA1=8851485a7134eb8743069439235c1a2a9728ea58
			CONFIGURE_COMMAND ""
			BUILD_COMMAND ""
			UPDATE_COMMAND ""
			INSTALL_COMMAND ""
		)

add_library(libgcc STATIC IMPORTED)
set_target_properties(libgcc PROPERTIES LINKER_LANGUAGE CXX)
set_target_properties(libgcc PROPERTIES IMPORTED_LOCATION exceptions/src/exceptions/libgcc.a)
add_dependencies(libgcc exceptions)

if (RTTI_EXCEPTIONS)
	add_library(cxxabi STATIC IMPORTED)
	set_target_properties(cxxabi PROPERTIES LINKER_LANGUAGE CXX)
	set_target_properties(cxxabi PROPERTIES IMPORTED_LOCATION exceptions/src/exceptions/libc++abi.a)
	add_dependencies(cxxabi exceptions)

	set(LDFLAGS "${LDFLAGS} --eh-frame-hdr")
	set(CXX_ABI_LIBS cxxabi)
endif()

# Machine image creation
function(add_machine_image NAME BINARY_NAME BINARY_DESC)
	add_executable(${NAME} ${ARGN})
	set_target_properties(${NAME} PROPERTIES OUTPUT_NAME ${BINARY_NAME})
	target_include_directories(${NAME} PRIVATE src)

	target_compile_definitions(${NAME} PRIVATE KERNEL_BINARY="${BINARY_NAME}")
	target_compile_definitions(${NAME} PRIVATE KERNEL_DESC="${BINARY_DESC}")

	add_subdirectory(${BBPATH}/ext ext)
	if (EASTL)
		target_link_libraries(${NAME} eastl)
	endif()

	add_subdirectory(${BBPATH}/src src)

	target_link_libraries(${NAME}
		# BUG: unfortunately, there is an LLD bug that prevents ASM objects
		# from linking with outside files that are in archives, unless they are
		# --whole-archived, but it is a small inconvinience to add these manually
		${KERNEL_LIBRARY}
		tinyprintf
		${CXX_ABI_LIBS}
		libgcc
		kernel
	)

	set_target_properties(${NAME} PROPERTIES LINK_FLAGS "${LDFLAGS}")
	# write out the binary name to a known file to simplify some scripts
	file(WRITE ${CMAKE_BINARY_DIR}/binary.txt ${BINARY_NAME})
endfunction()