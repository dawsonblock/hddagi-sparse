// Executes the compiled probe kernel on this machine's GPU and checks it against
// the CPU oracle fixtures.
//
// Pipeline: GLSL -> SPIR-V (glslang) -> MSL (spirv-cross) -> Metal. The MSL is
// compiled at runtime from the generated source, so what runs here is derived from
// the same shader text that will be shipped, not a hand-written reimplementation.
//
// Usage: run_probe <probe.msl> <fixtures.json> <fixtures.bin>

import Foundation
import Metal

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else {
    fail("usage: run_probe <probe.msl> <fixtures.json> <fixtures.bin>")
}

let mslPath = args[1]
let jsonPath = args[2]
let binPath = args[3]

guard let mslSource = try? String(contentsOfFile: mslPath, encoding: .utf8) else {
    fail("cannot read \(mslPath)")
}
guard let metaData = FileManager.default.contents(atPath: jsonPath),
      let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
      let count = meta["count"] as? Int,
      let layout = meta["layout"] as? [String: Any],
      let size = layout["size"] as? [Int],
      let cascades = layout["cascades"] as? Int,
      let pageSlots = meta["atlas_page_slots"] as? [Int] else {
    fail("cannot parse \(jsonPath)")
}
guard let fixtureData = FileManager.default.contents(atPath: binPath) else {
    fail("cannot read \(binPath)")
}

let recordBytes = 80
guard fixtureData.count == count * recordBytes else {
    fail("fixture size \(fixtureData.count) != \(count) * \(recordBytes)")
}

guard let device = MTLCreateSystemDefaultDevice() else {
    fail("no Metal device")
}

let library: MTLLibrary
do {
    library = try device.makeLibrary(source: mslSource, options: nil)
} catch {
    fail("MSL compile failed: \(error)")
}

guard let fn = library.makeFunction(name: "main0") else {
    fail("kernel main0 not found")
}

let pipeline: MTLComputePipelineState
do {
    pipeline = try device.makeComputePipelineState(function: fn)
} catch {
    fail("pipeline creation failed: \(error)")
}

guard let fixtureBuffer = device.makeBuffer(bytes: (fixtureData as NSData).bytes,
                                           length: fixtureData.count,
                                           options: .storageModeShared) else {
    fail("fixture buffer allocation failed")
}

let resultStride = 48
let resultBytes = count * resultStride
guard let resultBuffer = device.makeBuffer(length: resultBytes, options: .storageModeShared) else {
    fail("result buffer allocation failed")
}
memset(resultBuffer.contents(), 0, resultBytes)

// Push constant block, 10 x uint32, matching ProbePushConstants.
var pc = [UInt32](repeating: 0, count: 10)
pc[0] = UInt32(count)
pc[1] = UInt32(size[0])
pc[2] = UInt32(size[1])
pc[3] = UInt32(size[2])
pc[4] = UInt32(cascades)
pc[5] = UInt32(size[0] / 8)
pc[6] = UInt32(size[1] / 8)
pc[7] = UInt32(size[2] / 8)
pc[8] = UInt32(pageSlots[0])
pc[9] = UInt32(pageSlots[1])

guard let queue = device.makeCommandQueue(),
      let cmd = queue.makeCommandBuffer(),
      let enc = cmd.makeComputeCommandEncoder() else {
    fail("command encoding failed")
}

enc.setComputePipelineState(pipeline)
enc.setBytes(pc, length: pc.count * 4, index: 0)
enc.setBuffer(fixtureBuffer, offset: 0, index: 1)
enc.setBuffer(resultBuffer, offset: 0, index: 2)

let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
let groups = MTLSize(width: (count + 63) / 64, height: 1, depth: 1)
enc.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
enc.endEncoding()

cmd.commit()
cmd.waitUntilCompleted()

if let err = cmd.error {
    fail("command buffer error: \(err)")
}

// Verify.
let results = resultBuffer.contents().bindMemory(to: UInt32.self, capacity: resultBytes / 4)
var mismatches = 0
var firstBad = -1
for i in 0..<count {
    let base = i * (resultStride / 4)
    let parity = results[base + 10]
    if parity != 1 {
        mismatches += 1
        if firstBad < 0 { firstBad = i }
    }
}

let gpuName = device.name
print("device      : \(gpuName)")
print("kernel      : main0 (from SPIR-V via spirv-cross)")
print("records     : \(count)")
print("groups      : \(groups.width) x 64 threads")
if mismatches == 0 {
    print("RESULT      : PASS - 0 mismatches")
    exit(0)
} else {
    let base = firstBad * (resultStride / 4)
    print("RESULT      : FAIL - \(mismatches) mismatches, first at record \(firstBad)")
    print("  slot    got \(results[base + 0])")
    print("  wrapped got (\(results[base + 1]), \(results[base + 2]), \(results[base + 3]))")
    print("  region  got (\(Int32(bitPattern: results[base + 4])), \(Int32(bitPattern: results[base + 5])), \(Int32(bitPattern: results[base + 6])))")
    print("  texel   got (\(results[base + 7]), \(results[base + 8]), \(results[base + 9]))")
    exit(1)
}
