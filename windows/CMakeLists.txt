cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "dart_smb2")
project(${PROJECT_NAME} C)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src"
                 "${CMAKE_CURRENT_BINARY_DIR}/lifecycle")

cmake_policy(VERSION 3.14...3.25)

if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()

# ── libsmb2 Bundling ─────────────────────────────────────────────────────────
# libsmb2.dll is auto-downloaded from GitHub Releases per target arch. Two
# arches are supported (x86_64, arm64) and the binaries live in arch-scoped
# subdirectories: windows/libs/<arch>/libsmb2.dll. The CMake config detects
# the build's target arch and picks the matching subdir.
set(SMB2_RELEASE_VERSION  "libsmb2-r9")
# Populated from the SHA256SUMS artifact produced by native-release. The zero
# sentinel keeps an unpublished r9 binary from being mistaken for r8.
set(EXPECTED_SHA256_X86_64  "e8891bef110c9467bbd1e158a5e7b172fbb5e0f75a79f092cbdffb8fe4b24be1")
set(EXPECTED_SHA256_ARM64  "0ae0d61b28649273909c7796ed282331f07fcb8b2b91793854268ffa3378e127")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64|aarch64)$")
  set(_SMB2_ARCH         "arm64")
  set(_SMB2_RELEASE_NAME "libsmb2_windows-arm64.dll")
  set(_SMB2_EXPECTED_SHA "${EXPECTED_SHA256_ARM64}")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|x86_64|amd64)$")
  set(_SMB2_ARCH         "x86_64")
  set(_SMB2_RELEASE_NAME "libsmb2_windows-x86_64.dll")
  set(_SMB2_EXPECTED_SHA "${EXPECTED_SHA256_X86_64}")
else()
  message(FATAL_ERROR "[dart_smb2] Unsupported Windows arch: ${CMAKE_SYSTEM_PROCESSOR}. Supported: x86_64 (AMD64), arm64 (ARM64).")
endif()

set(_SMB2_LIB_DIR  "${CMAKE_CURRENT_SOURCE_DIR}/libs/${_SMB2_ARCH}")
set(_BUNDLED_SMB2  "${_SMB2_LIB_DIR}/libsmb2.dll")

set(DOWNLOAD_NEEDED TRUE)
if(DEFINED ENV{DART_SMB2_NATIVE_DIST} AND
   EXISTS "$ENV{DART_SMB2_NATIVE_DIST}/${_SMB2_RELEASE_NAME}")
  file(MAKE_DIRECTORY "${_SMB2_LIB_DIR}")
  # configure_file(COPYONLY) is supported by the plugin's minimum CMake,
  # unlike the newer file(COPY_FILE) command.
  configure_file(
    "$ENV{DART_SMB2_NATIVE_DIST}/${_SMB2_RELEASE_NAME}"
    "${_BUNDLED_SMB2}"
    COPYONLY)
  set(DOWNLOAD_NEEDED FALSE)
  message(STATUS "[dart_smb2] Using local libsmb2 artifact from DART_SMB2_NATIVE_DIST")
endif()

if(DOWNLOAD_NEEDED AND _SMB2_EXPECTED_SHA MATCHES "^0+$")
  message(FATAL_ERROR "[dart_smb2] libsmb2-r9 checksum for ${_SMB2_ARCH} is not published yet. Download SHA256SUMS and run dart run tool/update_native_checksums.dart SHA256SUMS libsmb2-r9.")
endif()

if(DOWNLOAD_NEEDED AND EXISTS "${_BUNDLED_SMB2}")
  file(SHA256 "${_BUNDLED_SMB2}" ACTUAL_SHA256)
  if(ACTUAL_SHA256 STREQUAL _SMB2_EXPECTED_SHA)
    set(DOWNLOAD_NEEDED FALSE)
  else()
    message(STATUS "[dart_smb2] SHA-256 mismatch for ${_SMB2_ARCH}: expected ${_SMB2_EXPECTED_SHA} but got ${ACTUAL_SHA256}. Redownloading...")
    file(REMOVE "${_BUNDLED_SMB2}")
  endif()
endif()

if(DOWNLOAD_NEEDED)
  message(STATUS "[dart_smb2] Downloading ${_SMB2_RELEASE_NAME} from GitHub Releases...")
  file(MAKE_DIRECTORY "${_SMB2_LIB_DIR}")
  file(DOWNLOAD
    "https://github.com/Stella2211/dart_smb2/releases/download/${SMB2_RELEASE_VERSION}/${_SMB2_RELEASE_NAME}"
    "${_BUNDLED_SMB2}"
    SHOW_PROGRESS
    EXPECTED_HASH SHA256=${_SMB2_EXPECTED_SHA}
    STATUS DOWNLOAD_STATUS
  )
  list(GET DOWNLOAD_STATUS 0 STATUS_CODE)
  if(NOT STATUS_CODE EQUAL 0)
    list(GET DOWNLOAD_STATUS 1 ERROR_MSG)
    message(FATAL_ERROR "[dart_smb2] Failed to download ${_SMB2_RELEASE_NAME}: ${ERROR_MSG}. Place it manually at ${_BUNDLED_SMB2}")
  endif()
endif()

if(EXISTS "${_BUNDLED_SMB2}")
  set(dart_smb2_bundled_libraries
    "${_BUNDLED_SMB2}"
    "$<TARGET_FILE:dart_smb2_lifecycle>"
    PARENT_SCOPE)
else()
  message(FATAL_ERROR "[dart_smb2] libsmb2.dll not found. It must be present at ${_BUNDLED_SMB2}")
endif()
