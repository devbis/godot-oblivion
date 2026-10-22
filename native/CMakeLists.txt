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
add_subdirectory("${NIFLY_PATH}" "${CMAKE_CURRENT_BINARY_DIR}/nifly")

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
            LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
            RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
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
endif()
