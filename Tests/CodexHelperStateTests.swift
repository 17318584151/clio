import Foundation

@main
struct CodexHelperStateTests {
    @MainActor
    static func main() throws {
        let cases: [(String, Bool, Bool)] = [
            (#"{"installed":true,"ready":false,"needsUpdate":false,"message":"配置不完整或服务未运行，可安装或修复。"}"#, true, true),
            (#"{"installed":true,"ready":false,"message":"已安装，配置不完整或服务未运行。"}"#, true, true),
            (#"{"installed":true,"ready":true,"needsUpdate":false,"message":"运行中"}"#, false, false),
            (#"{"installed":true,"ready":false,"needsUpdate":true,"message":"辅助服务可更新。"}"#, false, true),
            (#"{"installed":false,"ready":false,"message":"未安装。"}"#, false, true),
            (#"{"installed":true,"message":"安装失败。"}"#, true, true),
        ]
        for (json, repair, install) in cases {
            let response = try JSONDecoder().decode(CodexHelper.Response.self, from: Data(json.utf8))
            precondition(response.needsRepair == repair, "Incorrect repair action: \(json)")
            precondition(response.canInstall == install, "Incorrect installation gate: \(json)")
        }
        let failure = CodexHelper.Response(installed: false, message: "检测失败", failed: true)
        precondition(!failure.canInstall, "Detection failure must not request administrator authorisation")
        print("CodexHelper state checks passed (7 cases)")
    }
}
