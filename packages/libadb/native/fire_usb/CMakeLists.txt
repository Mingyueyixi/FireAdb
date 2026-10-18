cmake_minimum_required(VERSION 3.16)
project(fire_usb C)

# Runtime LoadLibrary/dlopen of libusb — do not link libusb here.
add_library(fire_usb SHARED fire_usb.c)
target_compile_definitions(fire_usb PRIVATE FIRE_USB_BUILD)
set_target_properties(fire_usb PROPERTIES
  C_VISIBILITY_PRESET hidden
  OUTPUT_NAME fire_usb
)

if(WIN32)
  set_target_properties(fire_usb PROPERTIES PREFIX "")
else()
  target_link_libraries(fire_usb PRIVATE ${CMAKE_DL_LIBS})
endif()

# vendor/<os>/<arch>/ — only the shared library is copied (not .lib/.exp/.obj).
if(WIN32)
  set(_os windows)
elseif(APPLE)
  set(_os macos)
else()
  set(_os linux)
endif()

# Prefer the *target* platform (-A ARM64), not the host CPU.
# With VS generator, CMAKE_SYSTEM_PROCESSOR often stays as the host (AMD64).
if(CMAKE_GENERATOR_PLATFORM MATCHES "^(ARM64|arm64)$")
  set(_arch arm64)
elseif(CMAKE_GENERATOR_PLATFORM MATCHES "^(x64|X64|Win32)$")
  set(_arch x64)
elseif(CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
  set(_arch arm64)
elseif(CMAKE_OSX_ARCHITECTURES STREQUAL "x86_64")
  set(_arch x64)
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|aarch64|arm64)$")
  set(_arch arm64)
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|x86_64|x64)$")
  set(_arch x64)
else()
  message(FATAL_ERROR "unsupported arch: generator=${CMAKE_GENERATOR_PLATFORM} processor=${CMAKE_SYSTEM_PROCESSOR}")
endif()

set(_vendor "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/${_os}/${_arch}")
message(STATUS "fire_usb install -> ${_vendor}")
add_custom_command(TARGET fire_usb POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${_vendor}"
  COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:fire_usb> "${_vendor}/"
  COMMENT "copy $<TARGET_FILE_NAME:fire_usb> -> vendor/${_os}/${_arch}/"
)
