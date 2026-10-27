import CryptoKit
import Foundation
import Network
import Security

public enum TLSConfig {
    public static func tlsOptions(psk: SymmetricKey, identity: String) -> NWProtocolTLS.Options {
        listenerOptions(keys: [(psk, identity)])
    }

    public static func listenerOptions(keys: [(SymmetricKey, String)]) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        for (key, identity) in keys {
            let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let idData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions,
                                                    keyData as __DispatchData, idData as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(options.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        return options
    }

    public static func parameters(control options: NWProtocolTLS.Options) -> NWParameters {
        // HAPTIC must not queue behind an unacknowledged STATUS/PONG segment (Nagle): disable coalescing.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: options, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: TGControlFramer.definition), at: 0)
        configure(parameters)
        return parameters
    }

    public static func parameters(input options: NWProtocolTLS.Options) -> NWParameters {
        let parameters = NWParameters(dtls: options, udp: NWProtocolUDP.Options())
        configure(parameters)
        return parameters
    }

    private static func configure(_ parameters: NWParameters) {
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.allowLocalEndpointReuse = true
    }
}
