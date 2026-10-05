cmake_minimum_required(VERSION 3.21)
project(WovenBrowser LANGUAGES C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}" libcef_dll_wrapper)
add_library(WovenBrowser STATIC WMBrowserBridge.mm)
target_include_directories(WovenBrowser PRIVATE "${CEF_ROOT}")
target_compile_options(WovenBrowser PRIVATE -fobjc-arc)
target_compile_definitions(WovenBrowser PRIVATE CEF_USE_SANDBOX)
add_executable(WovenBrowserHelper Helper.cc)
target_include_directories(WovenBrowserHelper PRIVATE "${CEF_ROOT}")
target_link_libraries(WovenBrowserHelper PRIVATE libcef_dll_wrapper "-framework Cocoa")

# State-machine tests compile the production bridge with CEF entry points
# substituted. They never load Chromium, create a profile, or use Keychain.
add_executable(WovenBrowserLifecycleTests EXCLUDE_FROM_ALL
  ../../scripts/test-support/BrowserLifecycleTests.mm)
target_include_directories(WovenBrowserLifecycleTests PRIVATE "${CEF_ROOT}")
target_compile_options(WovenBrowserLifecycleTests PRIVATE -fobjc-arc)
target_link_libraries(WovenBrowserLifecycleTests PRIVATE libcef_dll_wrapper "-framework Cocoa")
