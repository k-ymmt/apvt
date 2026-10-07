// apvt's loader: what `apvt setup` puts into the simulator's launchd environment as
// DYLD_INSERT_LIBRARIES, so every process the simulator starts afterwards loads it.
//
// It links nothing but libSystem and the Swift runtime and does nothing unless the process is
// a user-installed app (its executable lives under `/data/Containers/Bundle/Application/`).
// Then it dlopens the agent named by APVT_AGENT_PATH. Daemons and Apple's apps never load
// UIKit or the agent because of apvt.

import Darwin
import MachO

@used
@section("__DATA,__mod_init_func")
let apvtLoaderInitializer: @convention(c) () -> Void = {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
    var size = UInt32(buffer.count)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return }
    let path = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard path.contains("/data/Containers/Bundle/Application/"), let agent = getenv("APVT_AGENT_PATH") else { return }
    setenv("APVT_LOADED_BY", "launchd", 0) // keep a value the launcher set (apvt launch-env)
    if dlopen(agent, RTLD_NOW) == nil, let error = dlerror() {
        fputs("[apvt-loader] \(String(cString: error))\n", stderr)
    }
}
