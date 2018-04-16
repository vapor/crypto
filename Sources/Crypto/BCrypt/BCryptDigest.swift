import libbcrypt
import Random

/// Creates and verifies BCrypt hashes. Normally you will not need to initialize one of these classes and you will
/// use the global `BCrypt` convenience instead.
///
///     try BCrypt.hash("vapor", cost: 4)
///
/// See `BCrypt` for more information.
public final class BCryptDigest {
    /// Creates a new `BCryptDigest`. Use the global `BCrypt` convenience variable.
    public init() { }

    private enum Algorithm: String, RawRepresentable {
        /// older version
        case _2a = "$2a$"
        /// format specific to the crypt_blowfish BCrypt implementation, identical to `2b` in all but name.
        case _2y = "$2y$"
        /// latest revision of the official BCrypt algorithm, current default
        case _2b = "$2b$"

        var revisionCount: Int {
            return 4
        }

        /// Salt's length
        var saltCount: Int {
            return 29
        }

        /// Checksum's length
        var checksumCount: Int {
            return 31
        }
    }

    /// Encodes the provided plaintext using OpenBSD's Base 64 encoding
    ///
    /// - Parameter plaintext: Plaintext to encode
    /// - Returns: Base 64 encoded plaintext
    private func base64Encode(_ data: Data) throws -> String {
        let randomBytes = data.withUnsafeBytes {
            [UInt8](UnsafeBufferPointer(start: $0, count: data.count))
        }

        let encodedSaltBytes = UnsafeMutablePointer<Int8>.allocate(capacity: 25)
        encode_base64(encodedSaltBytes, randomBytes, randomBytes.count)

        return String(cString: encodedSaltBytes)
    }

    /// Encodes the provided plaintext using OpenBSD's Base 64 encoding
    ///
    /// - Parameter plaintext: Plaintext to encode
    /// - Returns: Base 64 encoded plaintext
    private func base64Encode(_ plaintext: String) throws -> String {
        guard let randomData = plaintext.data(using: .utf8) else {
            throw CryptoError(identifier: "invalidPlaintext", reason: "Invalid plaintext")
        }

        return try base64Encode(randomData)
    }

    /// Generates string (29 chars total) containing the algorithm information + the cost + base-64 encoded 22 character salt
    ///
    ///     E.g:  $2b$05$J/dtt5ybYUTCJ/dtt5ybYO
    ///           $AA$ => Algorithm
    ///              $CC$ => Cost
    ///                  SSSSSSSSSSSSSSSSSSSSSS => Salt
    ///
    /// Allowed charset for the salt: [./A-Za-z0-9]
    private func generateSalt(cost: UInt, algorithm: Algorithm = ._2b) throws -> String {
        let randomData = try URandom().generateData(count: 16)
        let encodedSalt = try base64Encode(randomData)

        return
            algorithm.rawValue +
            (cost < 10 ? "0\(cost)" : "\(cost)" ) +
            "$" +
            encodedSalt
    }

    /// Creates a BCrypt digest for the supplied data. `salt` will be generated.
    ///
    ///     try BCrypt.hash("vapor", cost: 4)
    ///
    /// - parameters:
    ///     - plaintext: Plaintext data to digest.
    ///     - cost: Desired complexity. Larger `cost` values take longer to hash and verify.
    /// - throws: `CryptoError` if hashing fails or if data conversion fails.
    /// - returns: BCrypt hash for the supplied plaintext data.
    public func hash(_ plaintext: String, cost: UInt = 12) throws -> String {
        let salt = try generateSalt(cost: cost)
        return try hash(plaintext, cost: cost, salt: salt)
    }

    /// Creates a BCrypt digest for the supplied data.
    ///
    /// Salt must be provided
    ///
    ///     try BCrypt.hash("vapor", cost: 12, salt: "passwordpassword")
    ///
    /// - parameters:
    ///     - plaintext: Plaintext data to digest.
    ///     - cost: Desired complexity. Larger `cost` values take longer to hash and verify.
    ///     - salt: Optional salt for this hash. If omitted, a random salt will be generated.
    ///             The salt must be 16-bytes.
    /// - throws: `CryptoError` if hashing fails or if data conversion fails.
    /// - returns: BCrypt hash for the supplied plaintext data.
    public func hash(_ plaintext: String, cost: UInt = 12, salt: String) throws -> String {
        let revisionString = String( salt.prefix(4) )
        guard let originalAlgorithm = Algorithm(rawValue: revisionString) else {
            throw CryptoError(identifier: "invalidSalt", reason: "Provided salt has the incorrect format")
        }

        let normalizedSalt: String
        if originalAlgorithm == Algorithm._2y {
            normalizedSalt = Algorithm._2b.rawValue + salt.dropFirst(originalAlgorithm.revisionCount)
        } else {
            normalizedSalt = salt
        }

        let hashedBytes = UnsafeMutablePointer<Int8>.allocate(capacity: 128)
        defer { hashedBytes.deallocate() }
        let hashingResult = bcrypt_hashpass(
            plaintext,
            normalizedSalt,
            hashedBytes,
            128
        )

        if hashingResult != 0 {
            throw CryptoError(identifier: "unableToComputeHash", reason: "Unable to compute BCrypt hash")
        } else {
            return originalAlgorithm.rawValue + String(cString: hashedBytes).dropFirst(originalAlgorithm.revisionCount)
        }
    }

    /// Verifies an existing BCrypt hash matches the supplied plaintext value. Verification works by parsing the salt and version from
    /// the existing digest and using that information to hash the plaintext data. If hash digests match, this method returns `true`.
    ///
    ///     let hash = try BCrypt.hash("vapor", cost: 4)
    ///     try BCrypt.verify("vapor", created: hash) // true
    ///     try BCrypt.verify("foo", created: hash) // false
    ///
    /// - parameters:
    ///     - plaintext: Plaintext data to digest and verify.
    ///     - hash: Existing BCrypt hash to parse version, salt, and existing digest from.
    /// - throws: `CryptoError` if hashing fails or if data conversion fails.
    /// - returns: `true` if the hash was created from the supplied plaintext data.
    public func verify(_ plaintext: String, created hash: String) throws -> Bool {
        guard let hashVersion = Algorithm(rawValue: String(hash.prefix(4)))
            else {
                throw CryptoError(identifier: "invalidHashFormat", reason: "No BCrypt revision information found")
        }

        let hashSalt = String(hash.prefix(hashVersion.saltCount))
        guard !hashSalt.isEmpty, hashSalt.count == hashVersion.saltCount
            else {
                throw CryptoError(identifier: "invalidHashFormat", reason: "BCrypt salt data not found or has incorrect length")
        }

        let hashChecksum = String(hash.suffix(hashVersion.checksumCount))
        guard !hashChecksum.isEmpty, hashChecksum.count == hashVersion.checksumCount
            else {
                throw CryptoError(identifier: "invalidHashFormat", reason: "BCrypt hash data not found or has incorrect length")
        }

        let messageHash = try self.hash(plaintext, salt: hashSalt)
        let messageHashChecksum = String(messageHash.suffix(hashVersion.checksumCount))

        return messageHashChecksum == hashChecksum
    }
}

// MARK: BCrypt

/// Creates and verifies BCrypt hashes.
///
/// Use BCrypt to create hashes for sensitive information like passwords.
///
///     try BCrypt.hash("vapor", cost: 4)
///
/// BCrypt uses a random salt each time it creates a hash. To verify hashes, use the `verify(_:matches)` method.
///
///     let hash = try BCrypt.hash("vapor", cost: 4)
///     try BCrypt.verify("vapor", created: hash) // true
///
/// https://en.wikipedia.org/wiki/Bcrypt
public var BCrypt: BCryptDigest {
    return .init()
}