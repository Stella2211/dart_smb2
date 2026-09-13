cmake_minimum_required(VERSION 3.10)
project(dart_smb2_lifecycle C)

# This helper stores native completions; libsmb2 stays an unmodified binary.
# Function pointers are passed by Dart, so no link to libsmb2 is required.
add_library(dart_smb2_lifecycle SHARED smb2_lifecycle.c)
target_compile_features(dart_smb2_lifecycle PRIVATE c_std_99)
find_package(Threads REQUIRED)
target_link_libraries(dart_smb2_lifecycle PRIVATE Threads::Threads)
set_target_properties(dart_smb2_lifecycle PROPERTIES
  C_VISIBILITY_PRESET hidden
)
