# Android: libjpeg-turbo built by scripts/build-android.sh into deps-install.
if(NOT TARGET JPEG::JPEG)
  add_library(JPEG::JPEG STATIC IMPORTED GLOBAL)
  set_target_properties(JPEG::JPEG PROPERTIES
    IMPORTED_LOCATION "${ORCA_ANDROID_PREFIX}/lib/libjpeg.a"
    INTERFACE_INCLUDE_DIRECTORIES "${ORCA_ANDROID_PREFIX}/include")
endif()
set(JPEG_FOUND TRUE)
set(JPEG_INCLUDE_DIRS "${ORCA_ANDROID_PREFIX}/include")
set(JPEG_INCLUDE_DIR "${ORCA_ANDROID_PREFIX}/include")
set(JPEG_LIBRARIES JPEG::JPEG)
