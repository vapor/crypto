import Foundation
import Core

/// The requested amount of output bytes from the key derivation
///
/// In circumstances with low iterations the amount of output bytes may not be met.
///
/// `digest.digestSize * iterations` is the amount of bytes stored in PBKDF2's buffer.
/// Any data added beyond this limit
public enum PBKDF2KeySize {
    case digestSize
    case fixed(Int)
    
    fileprivate func size(for digest: Digest) -> Int {
        switch self {
        case .digestSize:
            return numericCast(digest.algorithm.digestSize)
        case .fixed(let size):
            return size
        }
    }
}

/// PBKDF2 derives a fixed or custom length key from a password and salt.
///
/// It accepts a customizable amount of iterations to increase the algorithm weight and security.
///
/// Unlike BCrypt, the salt does not get stored in the final result,
/// meaning it needs to be generated and stored manually.
///
///     let passwordHasher = PBKDF2(digest: SHA1)
///     let salt = try CryptoRandom().generateData(count: 64) // Data
///     let hash = try passwordHasher.deriveKey(fromPassword: "secret", salt: salt, iterations: 15_000) // Data
///     print(hash.hexEncodedString()) // 8e55fa3015da583bb51b706371aa418afc8a0a44
///
/// PBKDF2 leans on HMAC for each iteration and can use all hash functions supported in Crypto
///
/// https://en.wikipedia.org/wiki/PBKDF2
public final class PBKDF2 {
    private let digest: Digest
    
    /// MD4 digest powered key derivation.
    ///
    /// https://en.wikipedia.org/wiki/MD4
    public static var MD4: PBKDF2 { return .init(digest: Crypto.MD4) }
    
    /// MD5 digest powered key derivation.
    ///
    /// https://en.wikipedia.org/wiki/MD5
    public static var MD5: PBKDF2 { return .init(digest: Crypto.MD5) }
    
    /// SHA-1 digest powered key derivation.
    ///
    /// https://en.wikipedia.org/wiki/SHA-1
    public static var SHA1: PBKDF2 { return .init(digest: Crypto.SHA1) }
    
    /// SHA-224 (SHA-2) digest powered key derivation.
    ///
    /// https://en.wikipedia.org/wiki/SHA-2
    public static var SHA224: PBKDF2 { return .init(digest: Crypto.SHA224) }
    
    /// SHA-256 (SHA-2) digest powered key derivation.
    ///
    /// https://en.wikipedia.org/wiki/SHA-2
    public static var SHA256: PBKDF2 { return .init(digest: Crypto.SHA256) }
    
    /// SHA-384 (SHA-2) digest powered key derivation.
    ///
    /// https://en.wikipedia.org/wiki/SHA-2
    public static var SHA384: PBKDF2 { return .init(digest: Crypto.SHA384) }
    
    /// SHA-512 (SHA-2) digest powered key derivation.
    ///
    /// https://en.wikipedia.org/wiki/SHA-2
    public static var SHA512: PBKDF2 { return .init(digest: Crypto.SHA512) }
    
    /// Creates a new PBKDF2 derivator based on a hashing algorithm
    public init(digest: Digest) {
        self.digest = digest
    }
    
    /// Authenticates a message using HMAC with precalculated keys (saves 50% performance)
    fileprivate func authenticate(
        _ message: Data,
        innerPadding: Data,
        outerPadding: Data
    ) throws -> Data {
        let innerPaddingHash = try self.digest.digest(innerPadding + message)
        return try self.digest.digest(outerPadding + innerPaddingHash)
    }
    
    /// Derives a key with up to `keySize` of bytes
    ///
    ///
    public func hash(
        _ password: LosslessDataConvertible,
        salt: LosslessDataConvertible,
        iterations: Int,
        keySize: PBKDF2KeySize = .digestSize
    ) throws -> Data {
        let chunkSize = numericCast(digest.algorithm.blockSize) as Int
        let digestSize = numericCast(digest.algorithm.digestSize) as Int
        let keySize = keySize.size(for: digest)
        var password = try password.convertToData()
        var salt = try salt.convertToData()
        
        // Check input values to be correct
        guard iterations > 0 else {
            throw CryptoError.custom(
                identifier: "noIterations",
                reason: """
                PBKDF2 was requested to iterate 0 times.
                This must be at least 1 iteration.
                10_000 is the recommended minimum for secure key derivations.
                """
            )
        }
        
        guard password.count > 0 else {
            throw CryptoError.custom(identifier: "emptySalt", reason: "The password provided to PBKDF2 was 0 bytes long")
        }
        
        guard salt.count > 0 else {
            throw CryptoError.custom(identifier: "emptySalt", reason: "The salt provided to PBKDF2 was 0 bytes long")
        }
        
        // `pow` is not available for `Int`
        guard keySize <= Int(((pow(2,32)) - 1) * Double(chunkSize)) else {
            throw CryptoError.custom(identifier: "emptySalt", reason: "The salt provided to PBKDF2 was 0 bytes long")
        }
        
        // Precalculate paddings to save 50% performance
        
        // If the key is too long, hash it first
        if password.count > chunkSize {
            password = try digest.digest(password)
        }
        
        // Add padding
        if password.count < chunkSize {
            password = password + Data(repeating: 0, count: chunkSize &- password.count)
        }
        
        // XOR the information
        var outerPadding = Data(repeating: 0x5c, count: chunkSize)
        var innerPadding = Data(repeating: 0x36, count: chunkSize)
        
        outerPadding ^= password
        innerPadding ^= password
        
        // This is where all the key derivation happens
        let blocks = UInt32((keySize + digestSize - 1) / digestSize)
        var response = Data()
        response.reserveCapacity(keySize)
        
        let saltSize = salt.count
        
        // Add 4 bytes for the chunk block numbers
        salt.append(contentsOf: [0,0,0,0])
        
        // Loop over all blocks
        for block in 1...blocks {
            salt.withMutableByteBuffer { buffer in
                buffer.baseAddress!.advanced(
                    by: saltSize
                ).withMemoryRebound(
                    to: UInt32.self,
                    capacity: 1
                ) { pointer in
                    pointer.pointee = block.bigEndian
                }
            }
            
            // Iterate the first time
            var ui = try authenticate(salt, innerPadding: innerPadding, outerPadding: outerPadding)
            var u1 = ui
            
            // Continue iterating for this block
            for _ in 0..<iterations - 1 {
                u1 = try authenticate(u1, innerPadding: innerPadding, outerPadding: outerPadding)
                ui ^= u1
            }
            
            // Append the response to be returned
            response.append(contentsOf: ui)
        }
        
        // In the scenarios where the keySize is not the digestSize we have to make a slice
        if response.count > keySize {
            return Data(response[0..<keySize])
        } else {
            // Otherwise we can use a more direct return which is more performant
            return response
        }
    }
}

/// XORs the lhs bytes with the rhs bytes on the same index
///
/// Assumes and asserts lhs and rhs to have an equal count
fileprivate func ^=(lhs: inout Data, rhs: Data) {
    // These two must be equal for the PBKDF2 implementation to be correct
    assert(lhs.count == rhs.count)
    
    // Foundation does not guarantee that Data is a top-level blob
    // It may be a sliced blob with a startIndex of > 0
    var lhsIndex = lhs.startIndex
    var rhsIndex = rhs.startIndex
    
    for _ in 0..<lhs.count {
        lhs[lhsIndex] = lhs[lhsIndex] ^ rhs[rhsIndex]
        
        lhsIndex += 1
        rhsIndex += 1
    }
}
