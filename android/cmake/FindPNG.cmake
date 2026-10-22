# Android: libpng built by scripts/build-android.sh into deps-install.
if(NOT TARGET PNG::PNG)
  add_library(PNG::PNG STATIC IMPORTED GLOBAL)
  set_target_properties(PNG::PNG PROPERTIES
    IMPORTED_LOCATION "${ORCA_ANDROID_PREFIX}/lib/libpng16.a"
    INTERFACE_INCLUDE_DIRECTORIES "${ORCA_ANDROID_PREFIX}/include"
    INTERFACE_LINK_LIBRARIES ZLIB::ZLIB)
endif()
set(PNG_FOUND TRUE)
set(PNG_INCLUDE_DIRS "${ORCA_ANDROID_PREFIX}/include")
set(PNG_LIBRARIES PNG::PNG)
set(PNG_VERSION_STRING "1.6.43")
