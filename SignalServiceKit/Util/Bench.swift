//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Benchmark time for async code by calling the passed in block parameter when the work
/// is done.
///
///     foo(fooCompletion: (Error?) -> ()) {
///         BenchAsync(title: "my benchmark") { completeBenchmark in
///             bar { error in
///
///                 // consider benchmarking of "foo" complete
///                 completeBenchmark()
///
///                 // call any completion handler foo might have
///                 fooCompletion(error)
///             }
///         }
///     }
private func BenchAsync(title: String, logInProduction: Bool = false, block: (@escaping () -> Void) -> Void) {
    let startTime = CACurrentMediaTime()
    block {
        let timeElapsed = CACurrentMediaTime() - startTime
        let formattedTime = String(format: "%0.2fms", timeElapsed * 1000)
        let logMessage = "[Bench] title: \(title), duration: \(formattedTime)"
        if logInProduction {
            Logger.info(logMessage)
        } else {
            Logger.debug(logMessage)
        }
    }
}

/// Benchmark time for synchronous code
///
///    Bench(title: "my benchmark") {
///        doSomethingComputationallyExpensive()
///    }
///
/// Can return values, or rethrow, from the calling function
///
///    func foo() throws -> Int {
///        return try Bench(title: "my benchmark") {
///            return try produceExpensiveInt()
///        }
///    }
///
public func Bench<T>(
    title: String,
    logIfLongerThan intervalLimit: TimeInterval = 0,
    logInProduction: Bool = false,
    block: () throws -> T
) rethrows -> T {
    let startTime = CACurrentMediaTime()
    let value = try block()
    let timeElapsed = CACurrentMediaTime() - startTime

    if timeElapsed > intervalLimit {
        let formattedTime = String(format: "%0.2fms", timeElapsed * 1000)
        let logMessage = "[Bench] title: \(title), duration: \(formattedTime)"
        if logInProduction {
            Logger.info(logMessage)
        } else {
            Logger.debug(logMessage)
        }
    }
    return value
}

public protocol MemorySampler {
    func sample()
}

/// Benchmark time and memory for synchronous code
///
///    Bench(title: "my benchmark", memorySamplerRatio: 0.001) { memorySampler in
///        for result in lotsOfResults {
///            process(result)
///
///            // Because memory usage can rise and fall, and what we are actually interested in
///            // is "peak" memory usage, we must occasionally "sample" memory usage at interesting
///            // times.
///            //
///            // Because measuring memory isn't free, we only do it probabilistically based
///            // on `memorySamplerRatio`.
///            // For example, on really tight loops, use a lower memorySamplerRatio. When you want
///            // every call to `sample` to actually take a measurement, set memorySamplerRatio
///            // to 1.0.
///            memorySampler.sample()
///        }
///    }
///
/// Can return values, or rethrow, from the calling function
///
///    func foo() throws -> Int {
///        return try Bench(title: "my benchmark") {
///            return try produceExpensiveInt()
///        }
///    }
///
public func BenchMemory<T>(
    title: String,
    memorySamplerRatio: Float,
    logInProduction: Bool = false,
    block: (MemorySampler) throws -> T
) rethrows -> T {
    let memoryBencher = MemoryBencher(
        title: title,
        logInProduction: logInProduction,
        sampleRatio: memorySamplerRatio
    )
    let value = try block(memoryBencher)
    memoryBencher.complete()
    return value
}

/// When it's not convenient to retain the event completion handler, e.g. when the measured event
/// crosses multiple classes, you can use the BenchEvent tools
///
///     // in one class
///     BenchEventStart(title: "message sending", eventId: message.id)
///     beginTheWork()
///
///     ...
///
///    // in another class
///    doTheLastThing()
///    BenchEventComplete(eventId: message.id)
///
/// Or in objc
///
///    [BenchManager startEventWithTitle:"message sending" eventId:message.id]
///    ...
///    [BenchManager completeEventWithEventId:message.id]
public func BenchEventStart(title: String, eventId: BenchmarkEventId, logInProduction: Bool = false) {
    BenchAsync(title: title, logInProduction: logInProduction) { finish in
        eventQueue.sync {
            runningEvents[eventId] = Event(title: title, eventId: eventId, completion: finish)
        }
    }
}

public func BenchEventComplete(eventId: BenchmarkEventId) {
    BenchEventComplete(eventIds: [eventId])
}

public func BenchEventComplete(eventIds: [BenchmarkEventId]) {
    eventQueue.sync {
        for eventId in eventIds {
            guard let event = runningEvents.removeValue(forKey: eventId) else {
                owsFailDebug("Can't end event that wasn't started.")
                return
            }
            event.completion()
        }
    }
}

public typealias BenchmarkEventId = String

private struct Event {
    let title: String
    let eventId: BenchmarkEventId
    let completion: () -> Void
}

private var runningEvents: [BenchmarkEventId: Event] = [:]
private let eventQueue = DispatchQueue(label: "org.signal.bench")

public class BenchManager {
    public static func bench(title: String, logIfLongerThan intervalLimit: TimeInterval, logInProduction: Bool, block: () -> Void) {
        Bench(title: title, logIfLongerThan: intervalLimit, logInProduction: logInProduction, block: block)
    }
}

// MARK: Memory

private class MemoryBencher: MemorySampler {
    @usableFromInline lazy var byteFormatter = ByteCountFormatter()

    let title: String
    let logInProduction: Bool

    /// 0.0-1.0 ratio of blocks to measure
    ///
    /// We run the block , and then, to minimize performance impact, we only sample memory usage
    /// some of the time, depending on the sampleRatio.
    @usableFromInline let sampleRatio: Float
    @usableFromInline var maxSize: mach_vm_size_t?
    @usableFromInline var initialSize: mach_vm_size_t?

    public init(
        title: String,
        logInProduction: Bool,
        sampleRatio: Float
    ) {
        self.title = title
        self.logInProduction = logInProduction
        self.sampleRatio = sampleRatio

        let currentSize = residentMemorySize()
        // technically can fail, but usually shouldn't
        // in any case, we don't want failure to bench memory
        // to interfere with control flow so swallow any errors
        assert(currentSize != nil)

        self.initialSize = currentSize
        self.maxSize = currentSize
    }

    public func complete() {
        sample()
        reportMemoryGrowth()
    }

    @inlinable
    public func sample() {
        guard
            sampleRatio > 0,
            Bool.trueWithProbability(ratio: sampleRatio)
        else {
            return
        }

        if let currentSize = residentMemorySize() {
            guard let maxSize = maxSize else {
                // Because the first thing we do in this method is set maxMemoryFootprint, this
                // shouldn't happen, but `residentMemorySize` _can_ fail and we don't want
                // a failure to measure memory to interfere with running the `block`.
                return
            }
            if currentSize > maxSize {
                self.maxSize = currentSize
            }
        }
    }

    @usableFromInline
    func reportMemoryGrowth() {
        guard let initialSize = initialSize,
            let maxSize = maxSize else {
                owsFailDebug("counts were unexpectedly nil")
                return
        }

        let initialBytes = byteFormatter.string(fromByteCount: Int64(initialSize))
        let maxBytes = byteFormatter.string(fromByteCount: Int64(maxSize))
        let growthBytes = byteFormatter.string(fromByteCount: Int64(maxSize - initialSize))

        let benchMessage = "[Bench] title: \(title) memory: \(initialBytes) -> \(maxBytes) (+\(growthBytes))"
        if logInProduction {
            Logger.info(benchMessage)
        } else {
            Logger.debug(benchMessage)
        }
    }

    @usableFromInline
    func residentMemorySize() -> mach_vm_size_t? {
        var info = mach_task_basic_info()
        let MACH_TASK_BASIC_INFO_COUNT = MemoryLayout<mach_task_basic_info>.stride/MemoryLayout<natural_t>.stride
        var count = mach_msg_type_number_t(MACH_TASK_BASIC_INFO_COUNT)

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: MACH_TASK_BASIC_INFO_COUNT) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }

        if kerr == KERN_SUCCESS {
            return info.resident_size
        } else {
            let errorString = (String(cString: mach_error_string(kerr), encoding: String.Encoding.ascii) ?? "unknown error")
            owsFailDebug("error with task_info(): \(errorString)")
            return nil
        }
    }
}

public extension Bool {
    @inlinable
    static func trueWithProbability(ratio: Float) -> Bool {
        return (0..<ratio).contains(Float.random(in: 0..<1.0))
    }
}
