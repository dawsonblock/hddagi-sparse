// Executes the allocation kernel on this machine's GPU.
//
// Runs the three modes as three separate command buffers, which is the strongest
// form of the barrier requirement: each pass must complete and publish before the
// next reads its counters. Then it checks the properties that matter when the
// allocation order is not deterministic:
//
//   - every requested slot is either COMMITTED with a unique page, or OVERFLOWED
//   - the number allocated equals min(requests, capacity)
//   - no two slots share a page
//   - overflow is counted, not silently dropped
//
// Usage: run_manage <manage.msl> <slot_count> <capacity> <request_count>

import Foundation
import Metal

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 5 else { fail("usage: run_manage <manage.msl> <slot_count> <capacity> <request_count>") }
guard let source = try? String(contentsOfFile: args[1], encoding: .utf8) else { fail("cannot read msl") }
guard let slotCount = Int(args[2]), let capacity = Int(args[3]), let requestCount = Int(args[4]) else {
    fail("bad numeric arguments")
}
guard requestCount <= slotCount else { fail("request_count exceeds slot_count") }

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }

let pipeline: MTLComputePipelineState
do {
    let lib = try device.makeLibrary(source: source, options: nil)
    guard let fn = lib.makeFunction(name: "main0") else { fail("main0 missing") }
    pipeline = try device.makeComputePipelineState(function: fn)
} catch {
    fail("pipeline: \(error)")
}

func buffer(_ length: Int, _ label: String) -> MTLBuffer {
    guard let b = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
        fail("\(label) allocation failed")
    }
    memset(b.contents(), 0, b.length)
    return b
}

let wordCount = (slotCount + 31) / 32
let requests = buffer(wordCount * 4, "requests")
let table = buffer(slotCount * 16, "table")
let freeList = buffer(capacity * 4, "free_list")
let cursor = buffer(4, "cursor")
let compacted = buffer(slotCount * 4, "compacted")
let counters = buffer(32, "counters")
let allocated = buffer(capacity * 4, "allocated")
let metadata = buffer(capacity * 32, "metadata")

// Table starts with INVALID_PAGE and UNMAPPED for every slot.
let tablePtr = table.contents().bindMemory(to: UInt32.self, capacity: slotCount * 4)
for i in 0..<slotCount {
    tablePtr[i * 4 + 0] = 0xFFFF_FFFF
    tablePtr[i * 4 + 2] = 0 // SB_STATE_UNMAPPED
}

// Free list is page 0..capacity-1.
let freePtr = freeList.contents().bindMemory(to: UInt32.self, capacity: capacity)
for i in 0..<capacity { freePtr[i] = UInt32(i) }

// Request slots 100 ..< 100 + requestCount.
let requestPtr = requests.contents().bindMemory(to: UInt32.self, capacity: wordCount)
for i in 0..<requestCount {
    let slot = 100 + i
    requestPtr[slot / 32] |= (1 << UInt32(slot % 32))
}

let queue = device.makeCommandQueue()!

func runMode(_ mode: UInt32, groups: Int, label: String) {
    var pc = [UInt32](repeating: 0, count: 10)
    pc[0] = mode
    pc[1] = UInt32(wordCount)
    pc[2] = UInt32(slotCount)
    pc[3] = UInt32(capacity)
    pc[4] = 1 // epoch
    pc[5] = 1000 // generation base
    pc[6] = 2048
    pc[7] = 16
    pc[8] = 8
    pc[9] = 16

    guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
        fail("encode failed")
    }
    enc.setComputePipelineState(pipeline)
    enc.setBytes(pc, length: 40, index: 1) // pc is buffer(1) in the generated MSL
    enc.setBuffer(requests, offset: 0, index: 0)
    enc.setBuffer(counters, offset: 0, index: 2)
    enc.setBuffer(compacted, offset: 0, index: 3)
    enc.setBuffer(cursor, offset: 0, index: 4)
    enc.setBuffer(table, offset: 0, index: 5)
    enc.setBuffer(freeList, offset: 0, index: 6)
    enc.setBuffer(metadata, offset: 0, index: 7)
    enc.setBuffer(allocated, offset: 0, index: 8)
    enc.dispatchThreadgroups(MTLSize(width: max(groups, 1), height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    if let e = cmd.error { fail("\(label): \(e)") }
}

runMode(0, groups: (wordCount + 63) / 64, label: "compact")
// Allocate is dispatched over every slot: the compacted list can exceed capacity.
runMode(1, groups: (slotCount + 63) / 64, label: "allocate")
runMode(2, groups: (capacity + 63) / 64, label: "initialize")

let c = counters.contents().bindMemory(to: UInt32.self, capacity: 8)
let compactedCount = Int(c[1])
let allocatedCount = Int(c[2])
let overflow = Int(c[3])
let committed = Int(c[4])

var committedSlots = 0
var overflowedSlots = 0
var distinctPages = Set<UInt32>()
var duplicatePage = false
for i in 0..<requestCount {
    let slot = 100 + i
    let base = slot * 4
    let page = tablePtr[base + 0]
    let state = tablePtr[base + 2]
    if state == 4 { // COMMITTED
        committedSlots += 1
        if distinctPages.contains(page) { duplicatePage = true }
        distinctPages.insert(page)
    } else if state == 8 { // OVERFLOWED
        overflowedSlots += 1
    }
}

let expectedAllocated = min(requestCount, capacity)
var ok = true
func check(_ cond: Bool, _ msg: String) {
    if !cond { print("  FAIL: \(msg)"); ok = false }
}

print("device      : \(device.name)")
print("slots       : \(slotCount), capacity \(capacity), requests \(requestCount)")
print("counters    : compacted \(compactedCount), allocated \(allocatedCount), overflow \(overflow), committed \(committed)")

check(compactedCount == requestCount, "compacted_count != request_count")
check(allocatedCount == expectedAllocated, "allocated != min(requests, capacity)")
check(overflow == requestCount - expectedAllocated, "overflow count wrong")
check(committed == expectedAllocated, "committed != allocated")
check(committedSlots == expectedAllocated, "committed table slots wrong")
check(overflowedSlots == requestCount - expectedAllocated, "overflowed table slots wrong")
check(!duplicatePage, "a page was handed to two slots")
check(distinctPages.count == expectedAllocated, "distinct page count wrong")

if ok {
    print("RESULT      : PASS")
    exit(0)
} else {
    print("RESULT      : FAIL")
    exit(1)
}
