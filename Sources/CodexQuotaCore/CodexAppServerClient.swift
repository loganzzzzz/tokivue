import Foundation

public final class CodexAppServerClient {
    public typealias FetchCompletion = (Result<QuotaSnapshot, Error>) -> Void

    private enum ConnectionState {
        case stopped
        case initializing
        case ready
    }

    private struct PendingRequest {
        let timeout: DispatchWorkItem
        let completion: (Result<[String: Any], Error>) -> Void
    }

    private let queue = DispatchQueue(label: "com.local.codex-quota.app-server")
    private let callbackQueue: DispatchQueue
    private var state: ConnectionState = .stopped
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var errorTail = Data()
    private var executableURL: URL?
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var readyWaiters: [(Result<Void, Error>) -> Void] = []
    private var updateHandler: (() -> Void)?
    private var connectionGeneration: UInt64 = 0

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    deinit {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    public func setRateLimitsUpdatedHandler(_ handler: (() -> Void)?) {
        queue.async { [weak self] in
            self?.updateHandler = handler
        }
    }

    public func fetch(executableURL: URL, completion: @escaping FetchCompletion) {
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureReady(executableURL: executableURL) { result in
                switch result {
                case .success:
                    self.sendRequest(
                        method: "account/rateLimits/read",
                        params: [:],
                        timeout: 12
                    ) { response in
                        let parsed = response.flatMap { object in
                            Result { try QuotaResponseParser.parse(jsonObject: object) }
                        }
                        self.callbackQueue.async {
                            completion(parsed)
                        }
                    }
                case let .failure(error):
                    self.callbackQueue.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopLocked(error: CodexQuotaError.connectionClosed)
        }
    }

    public static func fetchOnce(
        executableURL: URL,
        timeout: TimeInterval = 15
    ) throws -> QuotaSnapshot {
        let callbackQueue = DispatchQueue(label: "com.local.codex-quota.fetch-once")
        let client = CodexAppServerClient(callbackQueue: callbackQueue)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<QuotaSnapshot, Error>?

        client.fetch(executableURL: executableURL) {
            result = $0
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            client.stop()
            throw CodexQuotaError.requestTimedOut
        }
        client.stop()
        return try result?.get() ?? { throw CodexQuotaError.connectionClosed }()
    }

    private func ensureReady(
        executableURL requestedURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if executableURL?.standardizedFileURL != requestedURL.standardizedFileURL {
            stopLocked(error: CodexQuotaError.connectionClosed)
        }

        switch state {
        case .ready:
            completion(.success(()))
        case .initializing:
            readyWaiters.append(completion)
        case .stopped:
            readyWaiters.append(completion)
            startLocked(executableURL: requestedURL)
        }
    }

    private func startLocked(executableURL: URL) {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            finishInitialization(.failure(CodexQuotaError.executableNotRunnable(executableURL.path)))
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputPipe.fileHandleForReading
        self.errorHandle = errorPipe.fileHandleForReading
        self.executableURL = executableURL.standardizedFileURL
        self.outputBuffer.removeAll(keepingCapacity: true)
        self.errorTail.removeAll(keepingCapacity: true)
        self.state = .initializing
        self.connectionGeneration &+= 1
        let generation = self.connectionGeneration

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                self?.consumeOutput(data, generation: generation)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                self?.consumeErrorOutput(data, generation: generation)
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.queue.async { [weak self] in
                self?.handleTermination(
                    status: terminatedProcess.terminationStatus,
                    generation: generation
                )
            }
        }

        do {
            try process.run()
        } catch {
            stopLocked(error: CodexQuotaError.launchFailed(error.localizedDescription))
            return
        }

        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_quota_menubar",
                    "title": "Codex Quota Menu",
                    "version": "0.1.0",
                ],
            ],
            timeout: 10
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                do {
                    try self.sendNotification(method: "initialized", params: [:])
                    self.state = .ready
                    self.finishInitialization(.success(()))
                } catch {
                    self.stopLocked(error: error)
                }
            case let .failure(error):
                self.stopLocked(error: error)
            }
        }
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        timeout: TimeInterval,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let id = nextRequestID
        nextRequestID += 1

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self, let request = self.pending.removeValue(forKey: id) else { return }
            request.completion(.failure(CodexQuotaError.requestTimedOut))
            self.stopLocked(error: CodexQuotaError.requestTimedOut)
        }
        pending[id] = PendingRequest(timeout: timeoutItem, completion: completion)

        do {
            try writeMessage(["method": method, "id": id, "params": params])
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        } catch {
            pending.removeValue(forKey: id)?.timeout.cancel()
            completion(.failure(error))
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try writeMessage(["method": method, "params": params])
    }

    private func writeMessage(_ message: [String: Any]) throws {
        guard let inputHandle else { throw CodexQuotaError.connectionClosed }
        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        } catch {
            throw CodexQuotaError.invalidResponse("无法编码请求")
        }
        data.append(0x0A)
        do {
            try inputHandle.write(contentsOf: data)
        } catch {
            throw CodexQuotaError.connectionClosed
        }
    }

    private func consumeOutput(_ data: Data, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        guard !data.isEmpty else {
            outputHandle?.readabilityHandler = nil
            if process?.isRunning != true {
                handleTermination(
                    status: process?.terminationStatus ?? -1,
                    generation: generation
                )
            }
            return
        }

        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            consumeLine(Data(line))
        }
    }

    private func consumeLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = (object["id"] as? NSNumber)?.intValue,
           let request = pending.removeValue(forKey: id) {
            request.timeout.cancel()
            if let error = object["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue
                let message = (error["message"] as? String) ?? "未知错误"
                request.completion(.failure(CodexQuotaError.rpcError(code: code, message: message)))
            } else {
                request.completion(.success(object))
            }
            return
        }

        if object["method"] as? String == "account/rateLimits/updated",
           let updateHandler {
            callbackQueue.async {
                updateHandler()
            }
        }
    }

    private func consumeErrorOutput(_ data: Data, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        guard !data.isEmpty else {
            errorHandle?.readabilityHandler = nil
            return
        }
        errorTail.append(data)
        if errorTail.count > 4_096 {
            errorTail.removeFirst(errorTail.count - 4_096)
        }
    }

    private func finishInitialization(_ result: Result<Void, Error>) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter(result)
        }
    }

    private func handleTermination(status: Int32, generation: UInt64) {
        guard generation == connectionGeneration, process != nil else { return }
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        executableURL = nil
        state = .stopped

        let error = CodexQuotaError.processExited(status)
        let pendingRequests = pending.values
        pending.removeAll()
        for request in pendingRequests {
            request.timeout.cancel()
            request.completion(.failure(error))
        }
        finishInitialization(.failure(error))
    }

    private func stopLocked(error: Error) {
        connectionGeneration &+= 1
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? inputHandle?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        executableURL = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorTail.removeAll(keepingCapacity: false)
        state = .stopped

        let pendingRequests = pending.values
        pending.removeAll()
        for request in pendingRequests {
            request.timeout.cancel()
            request.completion(.failure(error))
        }
        finishInitialization(.failure(error))
    }
}
