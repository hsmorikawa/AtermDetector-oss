import Foundation

/// コマンドライン引数の解析結果。
struct CLIOptions: Equatable {
    var clean = false
    var singleIP: String?
    var showHelp = false

    enum ParseError: Error, Equatable {
        case unknownArgument(String)
        case missingValue(String)
        case invalidIP(String)
    }

    static func parse(_ args: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = args.startIndex
        while index < args.endIndex {
            let arg = args[index]
            switch arg {
            case "--clean":
                options.clean = true
            case "--help", "-h":
                options.showHelp = true
            case "--ip":
                let next = args.index(after: index)
                guard next < args.endIndex else { throw ParseError.missingValue("--ip") }
                let value = args[next]
                guard IPv4.isValid(value) else { throw ParseError.invalidIP(value) }
                options.singleIP = value
                index = next
            default:
                throw ParseError.unknownArgument(arg)
            }
            index = args.index(after: index)
        }
        return options
    }
}
