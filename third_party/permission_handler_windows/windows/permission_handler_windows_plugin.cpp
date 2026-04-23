#include "include/permission_handler_windows/permission_handler_windows_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <map>
#include <string>

#include "permission_constants.h"

namespace {

using namespace flutter;

class PermissionHandlerWindowsPlugin : public Plugin {
 public:
  static void RegisterWithRegistrar(PluginRegistrar* registrar);

  PermissionHandlerWindowsPlugin();

  virtual ~PermissionHandlerWindowsPlugin();

  // Disallow copy and move.
  PermissionHandlerWindowsPlugin(const PermissionHandlerWindowsPlugin&) = delete;
  PermissionHandlerWindowsPlugin& operator=(const PermissionHandlerWindowsPlugin&) = delete;

  // Called when a method is called on the plugin channel.
  void HandleMethodCall(const MethodCall<>&,
                        std::unique_ptr<MethodResult<>>);
};

// static
void PermissionHandlerWindowsPlugin::RegisterWithRegistrar(
    PluginRegistrar* registrar) {

  auto channel = std::make_unique<MethodChannel<>>(
    registrar->messenger(), "flutter.baseflow.com/permissions/methods",
    &StandardMethodCodec::GetInstance());

  std::unique_ptr<PermissionHandlerWindowsPlugin> plugin = std::make_unique<PermissionHandlerWindowsPlugin>();

  channel->SetMethodCallHandler(
    [plugin_pointer = plugin.get()](const auto& call, auto result) {
      plugin_pointer->HandleMethodCall(call, std::move(result));
    });

  registrar->AddPlugin(std::move(plugin));
}

PermissionHandlerWindowsPlugin::PermissionHandlerWindowsPlugin(){
}

PermissionHandlerWindowsPlugin::~PermissionHandlerWindowsPlugin() = default;

void PermissionHandlerWindowsPlugin::HandleMethodCall(
    const MethodCall<>& method_call,
    std::unique_ptr<MethodResult<>> result) {
  
  auto methodName = method_call.method_name();
  if (methodName.compare("checkServiceStatus") == 0) {
    auto permission = (PermissionConstants::PermissionGroup)std::get<int>(*method_call.arguments());
    if (permission == PermissionConstants::PermissionGroup::LOCATION ||
        permission == PermissionConstants::PermissionGroup::LOCATION_ALWAYS ||
        permission == PermissionConstants::PermissionGroup::LOCATION_WHEN_IN_USE) {
        result->Success(EncodableValue((int)PermissionConstants::ServiceStatus::ENABLED));
        return;
    }
    if(permission == PermissionConstants::PermissionGroup::BLUETOOTH){
        result->Success(EncodableValue((int)PermissionConstants::ServiceStatus::ENABLED));
        return;
    }

    if (permission == PermissionConstants::PermissionGroup::IGNORE_BATTERY_OPTIMIZATIONS) {
        result->Success(EncodableValue((int)PermissionConstants::ServiceStatus::ENABLED));
        return;
    }

    result->Success(EncodableValue((int)PermissionConstants::ServiceStatus::NOT_APPLICABLE));
    
  } else if (methodName.compare("checkPermissionStatus") == 0) {
    result->Success(EncodableValue((int)PermissionConstants::PermissionStatus::GRANTED));
  } else if (methodName.compare("requestPermissions") == 0) {
    auto permissionsEncoded = std::get<EncodableList>(*method_call.arguments());
    EncodableMap requestResults;
    for (const auto& encoded : permissionsEncoded) {
      const auto permission = std::get<int>(encoded);
      requestResults.insert({
        EncodableValue(permission),
        EncodableValue((int)PermissionConstants::PermissionStatus::GRANTED)
      });
    }

    result->Success(requestResults);
  } else if (methodName.compare("shouldShowRequestPermissionRationale") == 0
          || methodName.compare("openAppSettings")) {
    result->Success(EncodableValue(false));
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void PermissionHandlerWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  PermissionHandlerWindowsPlugin::RegisterWithRegistrar(
      PluginRegistrarManager::GetInstance()
          ->GetRegistrar<PluginRegistrarWindows>(registrar));
}
