import Logging
import SwiftKafka
import NIOCore

#if os(macOS)
import Darwin
#else
import Glibc
#endif

@main
struct TestProducer {
    public static func main() async throws {
        guard let brokers = getenv("KAFKA_BROKERS") else {
            print("Specify Kafka brokers in KAFKA_BROKERS environment variable")
            return
        }

        var config = KafkaConfig()
        try config.set(String(validatingUTF8: brokers)!, forKey: "bootstrap.servers")
        try config.set("lz4", forKey: "compression.codec")

        let producer = try await KafkaProducer(config: config, logger: Logger(label: "producer-logger"))

        for i in 1 ... 10_000_000 {
            let key = ByteBuffer(string: "key \(i)")
            //let value = ByteBuffer(bytes: (1 ... 100).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) })
            let value = ByteBuffer(repeating: 42, count: 100)

            let message = KafkaProducerMessage(topic: "read-perf-test",
                                               key: key,
                                               value: value)

            try await producer.sendAsync(message)
        }

        await producer.shutdownGracefully()
    }
}
