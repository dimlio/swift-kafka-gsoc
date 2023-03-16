import Foundation
import Logging
import SwiftKafka

#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Get a timestamp value for statistics
/// - Returns: A timestamp value in microseconds
@inlinable
@inline(__always)
func getTimestamp() -> UInt64 {
    var ts = timespec()
    let result = clock_gettime(CLOCK_REALTIME, &ts)

    guard result == 0 else {
        fatalError("Failed to get current time in clock_gettime(), errno = \(errno)")
    }

    return UInt64(ts.tv_sec) * 1_000_000 + UInt64(ts.tv_nsec / 1_000)
}

struct RateCalculator {
    var count = 0
    var bytes = 0
    var lastTimestamp = getTimestamp()

    mutating func add(_ message: KafkaConsumerMessage) {
        //print("got message: \(message)")

        count += 1
        bytes += message.value.readableBytes

        if count == 1_000_000 {
            let timestamp = getTimestamp()
            let rate = UInt64(count * 1_000_000) / (timestamp - lastTimestamp)
            let rateBytes = (UInt64(bytes * 1_000_000) / (timestamp - lastTimestamp)) >> 20
            print("rate: \(rate) msgs/s, \(rateBytes) MiB/s")
            count = 0
            bytes = 0
            lastTimestamp = timestamp
        }
    }
}

@main
struct TestConsumer {
    public static func main() async throws {
        guard let brokers = getenv("KAFKA_BROKERS") else {
            print("Specify Kafka brokers in KAFKA_BROKERS environment variable")
            return
        }

        var config = KafkaConfig()
        try config.set(String(validatingUTF8: brokers)!, forKey: "bootstrap.servers")
        try config.set("earliest", forKey: "auto.offset.reset")

        let consumer = try KafkaConsumer(
            topics: ["read-perf-test"],
            groupID: "read-perf-test-\(getpid())",
            config: config,
            logger: Logger(label: "consumer-logger"))

        guard let method = CommandLine.arguments.dropFirst().first else {
            print("No consume methods specified, available ones: nio, poll, stream, queue")
            return
        }

        switch method {
        case "nio": await readWithNIOAsyncProducer(consumer)
        case "poll": await readWithPoll(consumer)
        case "stream": await readWithAsyncStream(consumer)
        case "queue": readWithDispatchQueue(consumer)
        default:
            print("Invalid consume method \"\(method)\" specified, available ones: nio, poll, stream, queue")
        }
    }

    static func readWithNIOAsyncProducer(_ consumer: KafkaConsumer) async {
        print("Consume using NIOAsyncSequenceProducer")

        var rateCalc = RateCalculator()

        for await messageResult in consumer.messages {
            guard case .success(let message) = messageResult else {
                fatalError("consumer returned failure: \(messageResult)")
            }

            rateCalc.add(message)
        }
    }

    static func readWithPoll(_ consumer: KafkaConsumer) async {
        print("Consume using raw poll")

        var rateCalc = RateCalculator()
        while true {
            guard let message = try! consumer.rawPoll() else {
                continue
            }

            rateCalc.add(message)
        }
    }

    static func readWithAsyncStream(_ consumer: KafkaConsumer) async {
        print("Consume using AsyncStream")

        let stream = AsyncStream<KafkaConsumerMessage> { continuation in
            let queue = DispatchQueue(label: "poll-queue")
            queue.async {
                while true {
                    guard let message = try! consumer.rawPoll() else {
                        continue
                    }
                    let yieldResult = continuation.yield(message)
                    switch yieldResult {
                    case .dropped, .terminated: fatalError("yield failed: \(yieldResult)")
                    default: break
                    }
                }
            }
        }

        var rateCalc = RateCalculator()
        for await message in stream {
            rateCalc.add(message)
        }
    }

    static func readWithDispatchQueue(_ consumer: KafkaConsumer) {
        print("Consume using DispatchQueue")

        let queue = DispatchQueue(label: "consume-queue")
        var rateCalc = RateCalculator()
        while true {
            guard let message = try! consumer.rawPoll() else {
                continue
            }

            queue.async {
                rateCalc.add(message)
            }
        }
    }
}
