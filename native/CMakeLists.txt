cmake_minimum_required(VERSION 3.22)
project(openob_data LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(ZLIB REQUIRED)

set(NIFLY_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../extern/nifly" CACHE PATH "Path to nifly sources")
if(NOT EXISTS "${NIFLY_PATH}/CMakeLists.txt")
    message(FATAL_ERROR "nifly sources are required at ${NIFLY_PATH}")
endif()
get_filename_component(NIFLY_PATH "${NIFLY_PATH}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

# nifly 1.0 omits the three legacy component-validity bytes from
# NiTransformInterpolator. Oblivion 10.1.0.106 writes them before dataRef, so
# nifly otherwise reads those bytes as the reference and rejects this skeleton.
# Compile a patched copy in the build tree; keep the externally supplied nifly
# checkout untouched.
set(_nifly_animation_source "${NIFLY_PATH}/src/Animation.cpp")
file(READ "${_nifly_animation_source}" _nifly_animation_contents)
set(_nifly_transform_sync_before [=[void NiTransformInterpolator::Sync(NiStreamReversible& stream) {
	stream.Sync(translation);
	stream.Sync(rotation);
	stream.Sync(scale);
	dataRef.Sync(stream);
}]=])
set(_nifly_transform_sync_after [=[void NiTransformInterpolator::Sync(NiStreamReversible& stream) {
	stream.Sync(translation);
	stream.Sync(rotation);
	stream.Sync(scale);
	if (stream.GetVersion().File() < V10_1_0_110) {
		bool trsValid[3]{};
		stream.Sync(trsValid);
	}
	dataRef.Sync(stream);
}]=])
string(FIND "${_nifly_animation_contents}" "${_nifly_transform_sync_before}" _nifly_transform_sync_position)
if(_nifly_transform_sync_position GREATER_EQUAL 0)
    string(REPLACE "${_nifly_transform_sync_before}" "${_nifly_transform_sync_after}"
        _nifly_animation_contents "${_nifly_animation_contents}")
elseif(NOT _nifly_animation_contents MATCHES "NiTransformInterpolator::Sync[^{]*\\{[^}]*V10_1_0_110")
    message(FATAL_ERROR "Unsupported nifly Animation.cpp: legacy NiTransformInterpolator fields are not handled")
endif()
set(_nifly_patched_source_dir "${CMAKE_CURRENT_BINARY_DIR}/nifly-patched")
file(MAKE_DIRECTORY "${_nifly_patched_source_dir}")
set(_nifly_patched_animation_source "${_nifly_patched_source_dir}/Animation.cpp")
file(WRITE "${_nifly_patched_animation_source}" "${_nifly_animation_contents}")

# nifly is built as a static library that ends up inside a shared module, so it needs PIC,
# and an unconfigured CMAKE_BUILD_TYPE would build it (and NIF parsing) without optimization.
# Both must be set before add_subdirectory so nifly picks them up.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
        string(APPEND CMAKE_CXX_FLAGS " -O2")
    elseif(MSVC)
        string(APPEND CMAKE_CXX_FLAGS " /O2")
    endif()
endif()
add_subdirectory("${NIFLY_PATH}" "${CMAKE_CURRENT_BINARY_DIR}/nifly")

# Replace only nifly's Animation.cpp with the build-tree compatibility copy.
get_target_property(_nifly_source_files nifly SOURCES)
set(_nifly_fixed_source_files)
foreach(_nifly_source IN LISTS _nifly_source_files)
    get_filename_component(_nifly_source_absolute "${_nifly_source}" ABSOLUTE BASE_DIR "${NIFLY_PATH}/src")
    if(_nifly_source_absolute STREQUAL _nifly_animation_source)
        list(APPEND _nifly_fixed_source_files "${_nifly_patched_animation_source}")
    else()
        list(APPEND _nifly_fixed_source_files "${_nifly_source_absolute}")
    endif()
endforeach()
set_property(TARGET nifly PROPERTY SOURCES "${_nifly_fixed_source_files}")

add_library(oblivion_data_core STATIC
    src/bsa_archive.cpp
    src/command_table.cpp
    src/esm4_database.cpp
    src/game_data.cpp
    src/nif_mesh.cpp
    src/script_lexer.cpp
    src/script_parser.cpp
    src/script_interpreter.cpp
    src/quest_runtime.cpp
    src/quest_stage.cpp
    src/quest_driver.cpp
)
target_include_directories(oblivion_data_core PUBLIC include)
target_link_libraries(oblivion_data_core PUBLIC ZLIB::ZLIB nifly)
set_target_properties(oblivion_data_core PROPERTIES POSITION_INDEPENDENT_CODE ON)
# ESM/BSA indexing is CPU-bound and runs during startup. Keep the data-reader
# optimized even when the surrounding Godot project uses an unconfigured CMake
# build type (which otherwise compiles this code without optimization).
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(oblivion_data_core PRIVATE -O2)
elseif(MSVC)
    target_compile_options(oblivion_data_core PRIVATE /O2)
endif()

add_executable(oblivion-inspect src/inspect_main.cpp)
target_link_libraries(oblivion-inspect PRIVATE oblivion_data_core)

option(OPENOB_BUILD_GDEXTENSION "Build the Godot GDExtension (requires godot-cpp)" ON)
if(OPENOB_BUILD_GDEXTENSION)
    set(GODOT_CPP_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../extern/godot-cpp" CACHE PATH "Path to godot-cpp")
    if(EXISTS "${GODOT_CPP_PATH}/CMakeLists.txt")
        set(GODOTCPP_API_VERSION "4.7" CACHE STRING "Godot GDExtension API version")
        add_subdirectory("${GODOT_CPP_PATH}" "${CMAKE_CURRENT_BINARY_DIR}/godot-cpp")
        add_library(oblivion_data SHARED
            src/oblivion_data_extension.cpp
        )
        target_include_directories(oblivion_data PRIVATE include)
        target_link_libraries(oblivion_data PRIVATE oblivion_data_core godot-cpp)
        if(APPLE)
            set_target_properties(oblivion_data PROPERTIES PREFIX "lib" SUFFIX ".dylib")
        elseif(WIN32)
            set_target_properties(oblivion_data PROPERTIES PREFIX "" SUFFIX ".dll")
        else()
            set_target_properties(oblivion_data PROPERTIES PREFIX "lib" SUFFIX ".so")
        endif()
        set_target_properties(oblivion_data PROPERTIES
            OUTPUT_NAME "oblivion_data"
            LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
        )
    else()
        message(STATUS "godot-cpp not found; building the standalone data reader only")
    endif()
endif()

option(OPENOB_BUILD_TESTS "Build format reader fixture tests" ON)
if(OPENOB_BUILD_TESTS)
    enable_testing()
    add_executable(format_fixture_tests
        tests/format_fixture_tests.cpp
    )
    target_link_libraries(format_fixture_tests PRIVATE oblivion_data_core)
    add_test(NAME format_fixture_tests COMMAND format_fixture_tests)
    add_executable(format_hardening_tests
        tests/format_hardening_tests.cpp
    )
    target_link_libraries(format_hardening_tests PRIVATE oblivion_data_core)
    add_test(NAME format_hardening_tests COMMAND format_hardening_tests)
endif()
