import Foundation

/// Submit exactly once; subsequent invocations of the same adapter only query a job.
public struct RemoteAsyncOptions: Codable, Equatable {
    public var pollIntervalSeconds: Double
    public var timeoutSeconds: Double
    public init(pollIntervalSeconds: Double = 5, timeoutSeconds: Double = 3600) {
        self.pollIntervalSeconds = pollIntervalSeconds; self.timeoutSeconds = timeoutSeconds
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard Set(values.allKeys.map(\.stringValue)).isSubset(of: ["pollIntervalSeconds", "timeoutSeconds"]) else {
            throw TapDoneError("INVALID_ASYNC_OPTIONS", "异步配置包含未知字段。")
        }
        pollIntervalSeconds = try values.decodeIfPresent(Double.self, forKey: Key(stringValue: "pollIntervalSeconds")!) ?? 5
        timeoutSeconds = try values.decodeIfPresent(Double.self, forKey: Key(stringValue: "timeoutSeconds")!) ?? 3600
        _ = try validated()
    }
    public func validated() throws -> Self {
        guard pollIntervalSeconds.isFinite, (2...300).contains(pollIntervalSeconds),
              timeoutSeconds.isFinite, (1...86400).contains(timeoutSeconds) else {
            throw TapDoneError("INVALID_ASYNC_OPTIONS", "查询间隔须为 2–300 秒，总超时须为 1–86400 秒。")
        }
        return self
    }
}

public struct RemoteJobCheckpoint: Codable, Equatable {
    public let jobID: String
    public let deadline: Date
    public let nextPollAt: Date
    public init(jobID: String, deadline: Date, nextPollAt: Date) {
        self.jobID = jobID; self.deadline = deadline; self.nextPollAt = nextPollAt
    }
}

/// The v2 envelope validates each adapter invocation; this validates remote job semantics.
public struct RemoteJobResponse {
    public enum Status: String { case submitted, running, succeeded, failed }
    public let status: Status
    public let jobID: String
    public let result: JSONValue?
    public let message: String?
    public static func decode(_ value: JSONValue?, expectedJobID: String?) throws -> Self {
        guard case .object(let object)? = value,
              Set(object.keys).isSubset(of: ["status", "jobID", "result", "message"]),
              case .string(let raw)? = object["status"], let status = Status(rawValue: raw),
              case .string(let jobID)? = object["jobID"], !jobID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              jobID.utf8.count <= 256, !jobID.contains("\0"),
              expectedJobID == nil || expectedJobID == jobID,
              expectedJobID == nil || status != .submitted else {
            throw TapDoneError("INVALID_REMOTE_RESULT", "远程状态、作业 ID 或返回字段无效，不能确认任务结果。")
        }
        let message: String?
        if let rawMessage = object["message"] {
            guard case .string(let text) = rawMessage else { throw TapDoneError("INVALID_REMOTE_RESULT", "远程 message 必须是字符串。") }
            message = text
        } else { message = nil }
        guard status != .succeeded || object["result"] != nil else {
            throw TapDoneError("REMOTE_OUTPUT_MISSING", "远程任务声称成功但未返回 result。")
        }
        return Self(status: status, jobID: jobID, result: object["result"], message: message)
    }
}
