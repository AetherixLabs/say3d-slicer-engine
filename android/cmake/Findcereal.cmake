# Android: header-only cereal installed into deps-install.
if(NOT TARGET cereal::cereal)
  add_library(cereal::cereal INTERFACE IMPORTED GLOBAL)
  target_include_directories(cereal::cereal INTERFACE "${ORCA_ANDROID_PREFIX}/include")
endif()
set(cereal_FOUND TRUE)
set(CEREAL_FOUND TRUE)
set(CEREAL_INCLUDE_DIR "${ORCA_ANDROID_PREFIX}/include")
