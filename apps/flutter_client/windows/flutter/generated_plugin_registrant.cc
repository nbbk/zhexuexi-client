//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_secure_storage_windows/flutter_secure_storage_windows_plugin.h>
#include <mmkv_win32/mmkv_win32_plugin.h>
#include <flutter_sing_box/flutter_sing_box_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterSecureStorageWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterSecureStorageWindowsPlugin"));
  MmkvWin32PluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MmkvWin32Plugin"));
  FlutterSingBoxPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterSingBoxPluginCApi"));
}
