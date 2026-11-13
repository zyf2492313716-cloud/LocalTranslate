import Foundation

/// 程序员代码命名风格格式化转换引擎（对齐 Bob 0.6.0 与 1.10.0 的变量命名核心特性）。
///
/// 针对开发场景，将翻译结果或自然语言词组一键转为五种主流代码标识符命名风格：
/// 1. lowerCamelCase: `getUserProfile` (小驼峰，变量/方法)
/// 2. UpperCamelCase: `GetUserProfile` (大驼峰/PascalCase，类/结构体)
/// 3. snake_case: `get_user_profile` (蛇形，Python/数据库字段)
/// 4. MACRO_CASE: `GET_USER_PROFILE` (大写蛇形，常量/宏定义)
/// 5. kebab-case: `get-user-profile` (短横线，URL/CSS/配置项)
enum CodeCaseFormatter {

    enum Style: String, CaseIterable {
        case lowerCamel = "lowerCamelCase"
        case upperCamel = "UpperCamelCase"
        case snake = "snake_case"
        case macro = "MACRO_CASE"
        case kebab = "kebab-case"

        var label: String {
            switch self {
            case .lowerCamel: return "小驼峰 (lowerCamelCase)"
            case .upperCamel: return "大驼峰 (UpperCamelCase)"
            case .snake: return "下划线 (snake_case)"
            case .macro: return "常量宏 (MACRO_CASE)"
            case .kebab: return "短横线 (kebab-case)"
            }
        }
    }

    /// 将任意文本拆分为干净的英文/数字词元列表
    static func tokenize(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 统一把下划线、短横线、常见符号替换为空格
        var sanitized = ""
        for char in trimmed {
            if char.isLetter || char.isNumber {
                sanitized.append(char)
            } else {
                sanitized.append(" ")
            }
        }

        // 处理驼峰与连续大写缩写跃迁（如 getUser -> get User, XMLParser -> XML Parser）
        var expanded = ""
        let chars = Array(sanitized)
        for i in 0..<chars.count {
            let current = chars[i]
            if i > 0 {
                let prev = chars[i - 1]
                // 1) 小写接大写：如 getUser -> get User
                if prev.isLowercase && current.isUppercase {
                    expanded.append(" ")
                }
                // 2) 连续大写接首字母大写：如 XMLParser -> XML Parser
                else if i + 1 < chars.count && prev.isUppercase && current.isUppercase && chars[i + 1].isLowercase {
                    expanded.append(" ")
                }
            }
            expanded.append(current)
        }

        let rawTokens = expanded.split(separator: " ").map(String.init)
        return rawTokens.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 转换为指定代码命名风格
    static func format(_ text: String, style: Style) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        switch style {
        case .lowerCamel:
            let first = tokens[0].lowercased()
            let rest = tokens.dropFirst().map { capitalizeFirst($0) }
            return first + rest.joined()

        case .upperCamel:
            return tokens.map { capitalizeFirst($0) }.joined()

        case .snake:
            return tokens.map { $0.lowercased() }.joined(separator: "_")

        case .macro:
            return tokens.map { $0.uppercased() }.joined(separator: "_")

        case .kebab:
            return tokens.map { $0.lowercased() }.joined(separator: "-")
        }
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first else { return "" }
        return String(first).uppercased() + word.dropFirst().lowercased()
    }
}
