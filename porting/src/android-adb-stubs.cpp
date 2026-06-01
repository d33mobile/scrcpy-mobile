//
//  android-adb-stubs.cpp
//
//  Android (NDK) build only. The prebuilt libadb-full.a (the in-process adb
//  host, task M1-5) does NOT include adb's mDNS/Bonjour, emulator-command, and
//  logd/pmsg-writer translation units. scrcpy's adb-host path
//  (adb_commandline_porting) never reaches those code paths, but a handful of
//  their entry points are still *referenced* by the adb objects that ARE in the
//  archive, so libscrcpy.so would otherwise have undefined dynamic symbols that
//  bionic refuses at dlopen (BIND_NOW for non-lazy relocs).
//
//  These are WEAK no-op definitions that let libscrcpy.so load and run the
//  non-adb paths (e.g. `scrcpy --help`, and the normal mirror/control flow,
//  which uses the host adb only via adb_commandline_porting). If/when the M2
//  app needs adb mDNS discovery, link the real adb objects (strong, override
//  these). They are intentionally minimal and clearly dead for scrcpy.
//
//  Compiled ONLY into the Android build; guard with !__APPLE__ defensively.
//

#if !defined(__APPLE__)

#include <string>
#include <optional>
#include <memory>
#include <vector>
#include <cstddef>
#include <cstdint>

// --- adb mDNS / Bonjour (adb_mdns.h, transport.h) -----------------------------
struct MdnsInfo {
    std::string service_name;
    std::string service_type;
    std::string addr;
    uint16_t port = 0;
    MdnsInfo(std::string_view name, std::string_view type, std::string_view a, uint16_t p)
        : service_name(name), service_type(type), addr(a), port(p) {}
};

__attribute__((weak)) bool using_bonjour(void) { return false; }
__attribute__((weak)) std::string mdns_check() { return std::string(); }
__attribute__((weak)) std::string mdns_list_discovered_services() { return std::string(); }
__attribute__((weak)) std::optional<MdnsInfo>
mdns_get_connect_service_info(const std::string&) { return std::nullopt; }
__attribute__((weak)) std::optional<MdnsInfo>
mdns_get_pairing_service_info(const std::string&) { return std::nullopt; }
__attribute__((weak)) bool
adb_secure_connect_by_service_name(const std::string&) { return false; }

// --- adb emulator command (adb_client.h) --------------------------------------
// Reference mangles as _Z25adb_send_emulator_commandiPPKcS0_ =
// (int, const char**, const char*) — argv is `const char**` (PPKc), NOT
// `const char* const*`. Match exactly.
__attribute__((weak)) int
adb_send_emulator_command(int /*argc*/, const char** /*argv*/,
                          const char* /*serial*/) { return 1; }

// --- liblog logd / pmsg writers (logd_writer.h / pmsg_writer.h) ----------------
// The undefined symbols mangle as `_Z9LogdWrite6log_idP8timespecP5iovecm`, i.e.
// first arg type is the enum named `log_id` (NDK's android/log.h `log_id_t` is
// `typedef enum log_id { ... } log_id_t`), 2nd/3rd are `timespec*`/`iovec*`,
// 4th is `size_t`(m). Match those exactly so the mangled names line up.
enum log_id {};
struct timespec;
struct iovec;

__attribute__((weak)) int
LogdWrite(log_id /*logId*/, struct timespec* /*ts*/, struct iovec* /*vec*/, size_t /*nr*/) {
    return 0;
}
__attribute__((weak)) void LogdClose() {}
__attribute__((weak)) int
PmsgWrite(log_id /*logId*/, struct timespec* /*ts*/, struct iovec* /*vec*/, size_t /*nr*/) {
    return 0;
}
__attribute__((weak)) void PmsgClose() {}

// --- adb-wifi TLS pairing (client/pairing/pairing_client.h) --------------------
// Dead path for the in-process adb host (no `adb pair`). The undefined symbol is
//   adbwifi::pairing::PairingClient::Create(const Data&, const PeerInfo&,
//                                           const Data&, const Data&)
// where Data = std::vector<uint8_t> and PeerInfo is a global struct. Mirror the
// exact name/namespace/params so the mangled name matches; return null.
struct PeerInfo {        // global ns => mangles as `8PeerInfo`
    uint8_t type;
    char data[1];
};
namespace adbwifi {
namespace pairing {
class PairingClient {
public:
    using Data = std::vector<uint8_t>;
    static std::unique_ptr<PairingClient>
    Create(const Data&, const PeerInfo&, const Data&, const Data&);
};
__attribute__((weak)) std::unique_ptr<PairingClient>
PairingClient::Create(const Data&, const PeerInfo&, const Data&, const Data&) {
    return nullptr;
}
}  // namespace pairing
}  // namespace adbwifi

#endif /* !__APPLE__ */
