import Darwin
import Foundation

enum ApplicationInstanceLockError: Error, Equatable {
    case alreadyRunning
    case unsafeLockDirectory
    case unsafeLockFile
    case unavailable
}

final class ApplicationInstanceLock {
    private let fileDescriptor: Int32

    init(lockURL: URL = ApplicationInstanceLock.defaultLockURL()) throws {
        let directoryURL = lockURL.deletingLastPathComponent()
        try Self.prepareDirectory(directoryURL)

        let descriptor = lockURL.path.withCString {
            open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw ApplicationInstanceLockError.unsafeLockFile
            }
            throw ApplicationInstanceLockError.unavailable
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(),
              status.st_nlink == 1 else {
            close(descriptor)
            throw ApplicationInstanceLockError.unsafeLockFile
        }

        guard fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            throw ApplicationInstanceLockError.unavailable
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK {
                throw ApplicationInstanceLockError.alreadyRunning
            }
            throw ApplicationInstanceLockError.unavailable
        }

        fileDescriptor = descriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    static func defaultLockURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Codex Pulse", isDirectory: true)
            .appendingPathComponent("app-instance.lock", isDirectory: false)
    }

    private static func prepareDirectory(_ directoryURL: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ApplicationInstanceLockError.unavailable
        }

        var status = stat()
        guard directoryURL.path.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == getuid(),
              status.st_mode & 0o022 == 0 else {
            throw ApplicationInstanceLockError.unsafeLockDirectory
        }
    }
}
