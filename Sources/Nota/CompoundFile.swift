import Foundation

/// An OLE2 compound file, read from memory: the small FAT file system inside
/// one file that the Office formats before 2007 keep their parts in, each part
/// a named stream. Only reading, and only what finding a top-level stream by
/// name needs — no writing, no timestamps, no class ids.
///
/// The file is a run of fixed-size sectors (512 bytes in version 3, 4096 in
/// version 4) after a header. The FAT says which sector follows which, so a
/// stream is a chain of sectors; the header lists the FAT's own sectors, and
/// past 109 of them a chain of DIFAT sectors lists the rest. Streams shorter
/// than the cutoff (4096 bytes in practice) are packed into 64-byte mini
/// sectors inside one big stream, the root entry's, with a mini FAT of their
/// own. The directory is itself a chain of 128-byte entries.
///
/// A file that is cut short or whose tables contradict each other — a chain
/// that loops, a sector past the end, a size its chain cannot hold — reads as
/// `nil`, never as a trap or a loop: these come from mail attachments and old
/// disks as often as from Excel.
struct CompoundFile {
    private let bytes: [UInt8]
    private let sectorSize: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: [UInt8]
    private let miniCutoff: Int
    /// The root storage's own streams, in directory order.
    private let streams: [Entry]

    private struct Entry {
        let name: String
        let start: UInt32
        let size: Int
    }

    private static let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let free: UInt32 = 0xFFFF_FFFF
    private static let miniSectorSize = 64

    var streamNames: [String] { streams.map(\.name) }

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 512, Array(bytes[0 ..< 8]) == Self.magic,
              let major = bytes.littleEndian16(at: 26),
              let shift = bytes.littleEndian16(at: 30),
              (major == 3 && shift == 9) || (major == 4 && shift == 12),
              bytes.littleEndian16(at: 32) == 6,
              let fatCount = bytes.littleEndian32(at: 44),
              let directoryStart = bytes.littleEndian32(at: 48),
              let miniCutoff = bytes.littleEndian32(at: 56),
              let miniFATStart = bytes.littleEndian32(at: 60),
              let difatStart = bytes.littleEndian32(at: 68)
        else { return nil }
        let sectorSize = 1 << shift
        self.bytes = bytes
        self.sectorSize = sectorSize
        self.miniCutoff = miniCutoff

        // The FAT's sectors: 109 in the header, the rest down the DIFAT chain,
        // where each sector's last slot is the next DIFAT sector.
        let sectorCount = (bytes.count - 1) / sectorSize
        var fatSectors: [Int] = []
        for slot in 0 ..< 109 {
            guard let sector = bytes.littleEndian32(at: 76 + slot * 4), sector < sectorCount else { continue }
            fatSectors.append(sector)
        }
        var difat = difatStart
        var difatSeen = Set<Int>()
        let perSector = sectorSize / 4
        while difat < sectorCount, fatSectors.count < fatCount {
            guard difatSeen.insert(difat).inserted else { return nil }
            let base = (difat + 1) * sectorSize
            for slot in 0 ..< perSector - 1 {
                guard let sector = bytes.littleEndian32(at: base + slot * 4), sector < sectorCount
                else { continue }
                fatSectors.append(sector)
            }
            guard let next = bytes.littleEndian32(at: base + (perSector - 1) * 4) else { break }
            difat = next
        }
        var fat: [UInt32] = []
        fat.reserveCapacity(min(fatSectors.count, fatCount) * perSector)
        for sector in fatSectors.prefix(fatCount) {
            let base = (sector + 1) * sectorSize
            for slot in 0 ..< perSector {
                guard let entry = bytes.littleEndian32(at: base + slot * 4) else { break }
                fat.append(UInt32(entry))
            }
        }
        self.fat = fat

        // The directory has no stated size in version 3; its chain is all
        // there is, and a chain can be no longer than the FAT.
        guard let directory = Self.read(chainFrom: UInt32(truncatingIfNeeded: directoryStart),
                                        size: nil, table: fat, sectorSize: sectorSize,
                                        source: bytes, sourceOffset: sectorSize),
              directory.count >= 128
        else { return nil }
        let entryCount = directory.count / 128
        func entry(_ index: Int) -> (name: String, type: UInt8, left: Int, right: Int, child: Int,
                                     start: UInt32, size: Int)? {
            guard index >= 0, index < entryCount else { return nil }
            let base = index * 128
            guard let nameLength = directory.littleEndian16(at: base + 64),
                  let left = directory.littleEndian32(at: base + 68),
                  let right = directory.littleEndian32(at: base + 72),
                  let child = directory.littleEndian32(at: base + 76),
                  let start = directory.littleEndian32(at: base + 116),
                  let sizeLow = directory.littleEndian32(at: base + 120),
                  let sizeHigh = directory.littleEndian32(at: base + 124)
            else { return nil }
            // The length counts bytes, the terminator included; version 3
            // writers leave garbage in the size's high half.
            let units = (0 ..< max(0, min(nameLength, 64) / 2 - 1)).compactMap {
                directory.littleEndian16(at: base + $0 * 2).map(UInt16.init)
            }
            let size = major == 3 ? sizeLow : sizeHigh << 32 | sizeLow
            return (String(decoding: units, as: UTF16.self), directory[base + 66], left, right, child,
                    UInt32(truncatingIfNeeded: start), size)
        }
        guard let root = entry(0), root.type == 5 else { return nil }

        // The mini stream is the root entry's own chain, in whole sectors.
        if root.size > 0 {
            guard root.size <= bytes.count,
                  let mini = Self.read(chainFrom: root.start, size: root.size, table: fat,
                                       sectorSize: sectorSize, source: bytes, sourceOffset: sectorSize),
                  let table = Self.read(chainFrom: UInt32(truncatingIfNeeded: miniFATStart), size: nil,
                                        table: fat, sectorSize: sectorSize, source: bytes,
                                        sourceOffset: sectorSize)
            else { return nil }
            miniStream = mini
            miniFAT = stride(from: 0, to: table.count - 3, by: 4).compactMap {
                table.littleEndian32(at: $0).map(UInt32.init)
            }
        } else {
            miniStream = []
            miniFAT = []
        }

        // The root's children are a tree threaded through left, right and
        // child links; only its streams are wanted, not those of storages
        // nested in it (an embedded object's own workbook, say).
        var found: [(index: Int, entry: Entry)] = []
        var pending = [root.child]
        var seen = Set<Int>()
        while let index = pending.popLast() {
            guard let node = entry(index), seen.insert(index).inserted else { continue }
            pending.append(node.left)
            pending.append(node.right)
            if node.type == 2 {
                found.append((index, Entry(name: node.name, start: node.start, size: node.size)))
            }
        }
        streams = found.sorted { $0.index < $1.index }.map(\.entry)
    }

    /// The stream called `name`, matched without regard to case; `nil` when
    /// there is none or its sectors cannot be read.
    func stream(named name: String) -> Data? {
        guard let entry = streams.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              entry.size <= bytes.count
        else { return nil }
        if entry.size == 0 { return Data() }
        let read = entry.size < miniCutoff
            ? Self.read(chainFrom: entry.start, size: entry.size, table: miniFAT,
                        sectorSize: Self.miniSectorSize, source: miniStream, sourceOffset: 0)
            : Self.read(chainFrom: entry.start, size: entry.size, table: fat,
                        sectorSize: sectorSize, source: bytes, sourceOffset: sectorSize)
        return read.map { Data($0) }
    }

    /// A chain's sectors joined, cut to `size` when there is one. Sector `n`
    /// sits at `sourceOffset + n * sectorSize` — the header takes the first
    /// sector of the file, nothing of the mini stream. `nil` for a chain that
    /// loops, leaves the table or the source, or ends before `size`.
    private static func read(chainFrom start: UInt32, size: Int?, table: [UInt32], sectorSize: Int,
                             source: [UInt8], sourceOffset: Int) -> [UInt8]? {
        let wanted = size.map { ($0 + sectorSize - 1) / sectorSize } ?? table.count
        var out: [UInt8] = []
        out.reserveCapacity(min(wanted, table.count) * sectorSize)
        var sector = start
        var steps = 0
        while sector != endOfChain, steps < wanted {
            // More steps than the table has entries can only be a loop.
            guard Int(sector) < table.count, steps < table.count else { return nil }
            let from = sourceOffset + Int(sector) * sectorSize
            guard from < source.count else { return nil }
            out.append(contentsOf: source[from ..< min(from + sectorSize, source.count)])
            sector = table[Int(sector)]
            steps += 1
        }
        // Without a size the chain must end on its own; one still going
        // after every entry of the table has been walked is a loop.
        guard let size else { return sector == endOfChain ? out : nil }
        return out.count >= size ? Array(out.prefix(size)) : nil
    }
}

extension Array where Element == UInt8 {
    /// The little-endian unsigned integers binary formats are written in, or
    /// `nil` past the end.
    func littleEndian16(at offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return Int(self[offset]) | Int(self[offset + 1]) << 8
    }

    func littleEndian32(at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (0 ..< 4).reduce(0) { $0 | Int(self[offset + $1]) << ($1 * 8) }
    }

    func littleEndian64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(self[offset + $1]) << UInt64($1 * 8) }
    }
}
