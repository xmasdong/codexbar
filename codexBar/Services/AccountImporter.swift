import Foundation

/// 解析外部导出的账号 JSON（accounts[].credentials 嵌套格式），转成 TokenAccount。
/// 兼容形如：
/// {
///   "accounts": [
///     { "credentials": { "access_token", "refresh_token", "id_token",
///                        "chatgpt_account_id", "email", "plan_type", "expires_at" } }
///   ]
/// }
struct AccountImporter {
    enum ImportError: LocalizedError {
        case invalidJSON
        case noAccounts
        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "JSON 格式无效"
            case .noAccounts: return "未找到任何账号"
            }
        }
    }

    /// 从 JSON 数据解析出账号列表。尽量复用 AccountBuilder 的字段解析（与 OAuth 授权一致），
    /// 缺失时用导出文件里的现成字段兜底。
    static func parse(_ data: Data) throws -> [TokenAccount] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ImportError.invalidJSON
        }

        // 支持的顶层结构：
        //  1) {accounts:[...]}     —— sub2api 导出
        //  2) [...]                —— 裸数组
        //  3) {access_token:...}   —— 顶层单账号（扁平 auth.json 风格，字段直接平铺）
        //  4) {credentials:{...}}  —— 顶层单账号带 credentials
        let rawAccounts: [[String: Any]]
        if let dict = root as? [String: Any] {
            if let arr = dict["accounts"] as? [[String: Any]] {
                rawAccounts = arr
            } else if dict["access_token"] != nil || dict["credentials"] != nil {
                rawAccounts = [dict]
            } else {
                throw ImportError.invalidJSON
            }
        } else if let arr = root as? [[String: Any]] {
            rawAccounts = arr
        } else {
            throw ImportError.invalidJSON
        }

        var out: [TokenAccount] = []
        for entry in rawAccounts {
            // credentials 可能嵌套，也可能字段直接平铺在 entry 上
            let cred = (entry["credentials"] as? [String: Any]) ?? entry
            guard let access = cred["access_token"] as? String, !access.isEmpty else { continue }
            let refresh = cred["refresh_token"] as? String ?? ""
            let idToken = cred["id_token"] as? String ?? ""

            // 先走 AccountBuilder（JWT 解析 account_id / email / plan / expiry，逻辑与授权一致）
            var account = AccountBuilder.build(from: OAuthTokens(
                accessToken: access, refreshToken: refresh, idToken: idToken
            ))

            // chatgptAccountId 兜底（API/auth.json 用）。两种字段名：chatgpt_account_id 或 account_id
            let credChatgptId = (cred["chatgpt_account_id"] as? String) ?? (cred["account_id"] as? String) ?? ""
            if account.chatgptAccountId.isEmpty, !credChatgptId.isEmpty {
                account.chatgptAccountId = credChatgptId
            }
            // accountId（去重键）兜底：token 解析不出来时
            if account.accountId.isEmpty {
                if !credChatgptId.isEmpty {
                    account.accountId = credChatgptId
                } else if let em = cred["email"] as? String, !em.isEmpty {
                    account.accountId = "email:\(em)"
                }
            }
            // chatgptAccountId 最终兜底到 accountId（保证 API header 非空）
            if account.chatgptAccountId.isEmpty {
                account.chatgptAccountId = account.accountId
            }
            if account.email.isEmpty, let em = cred["email"] as? String {
                account.email = em
            }
            if account.planType.isEmpty || account.planType == "free",
               let plan = cred["plan_type"] as? String, !plan.isEmpty {
                account.planType = plan
            }
            if account.expiresAt == nil, let exp = cred["expires_at"] as? String {
                let f = ISO8601DateFormatter()
                account.expiresAt = f.date(from: exp)
            }

            // 仍无 account_id 则跳过（无法去重/激活）
            guard !account.accountId.isEmpty else { continue }
            out.append(account)
        }

        guard !out.isEmpty else { throw ImportError.noAccounts }
        return out
    }
}
