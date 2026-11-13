cmake_minimum_required(VERSION 3.22.1)

project(aevis LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 共享底层：和 iOS 用的是同一个 .cpp（aevis-ios/shared-core）
set(SHARED_CORE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../shared-core)

add_library(aevis SHARED
        aevis_jni.cpp
        ${SHARED_CORE}/aevis_core.cpp)

target_include_directories(aevis PRIVATE ${SHARED_CORE})
target_compile_options(aevis PRIVATE -Wall -Wextra -fvisibility=hidden)
